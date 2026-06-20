# frozen_string_literal: true

require "harnas/events/assistant_message"
require "harnas/events/tool_use"
require "harnas/observation"
require "harnas/provider_carriers"
require "harnas/usage"

module Harnas
  module Ingestors
    # Pure function: an Anthropic Messages API wire response to an
    # Array of Event-args Hashes the caller should append to its Log.
    #
    # Produces:
    #   - one :assistant_message event carrying the concatenated text
    #     blocks, the normalized stop_reason, and the normalized usage
    #     (always emitted, even when text is empty, so the assistant's
    #     stop_reason and usage are always recorded)
    #   - zero or more :tool_use events, one per tool_use content block
    #     in the response, in content-array order
    class Anthropic
      STOP_REASON_MAP = {
        "end_turn" => :end_turn,
        "max_tokens" => :max_tokens,
        "tool_use" => :tool_use,
        "stop_sequence" => :stop_sequence,
        "refusal" => :refusal
      }.freeze

      def call(response)
        content = response["content"] || []
        stop    = STOP_REASON_MAP.fetch(response["stop_reason"], :other)
        wire_usage = response["usage"] || {}
        usage = Harnas::Usage.normalize(wire_usage)

        events = []
        events << assistant_event(content, stop, wire_usage, response)
        content.each do |block|
          events << tool_use_event(block) if block["type"] == "tool_use"
        end

        emit_tokens_consumed(usage)
        events
      end

      private

      def assistant_event(content, stop, usage, response)
        text = content.select { |b| b["type"] == "text" }.map { |b| b["text"].to_s }.join
        reasoning = reasoning_blocks(content)
        if carrier_data?(content)
          payload = {
            text: text,
            stop_reason: stop,
            usage: Harnas::Usage.normalize(usage),
            provider: "anthropic",
            model: response["model"]
          }
          payload[:content] = text_content_with_carrier(text) unless text.empty?
          payload[:reasoning] = reasoning if reasoning
          carrier_content = content.reject { |block| block["type"] == "tool_use" || block[:type] == "tool_use" }
          refs = ["payload.reasoning[0]"]
          refs << "payload.content[0]" unless text.empty?
          payload[:provider_items] = [
            ProviderCarriers.carrier(destination: "anthropic.messages", index: 0,
                                     kind: "anthropic.content", wire: carrier_content,
                                     canonical_refs: refs)
          ] unless carrier_content.empty?
          return { type: :assistant_message, payload: payload }
        end
        {
          type: :assistant_message,
          payload: Events::AssistantMessage.new(
            text: text, stop_reason: stop, usage: usage, reasoning: reasoning,
            provider: "anthropic", model: response["model"]
          ).to_h
        }
      end

      def reasoning_blocks(content)
        blocks = content.filter_map do |block|
          next unless block["type"] == "thinking"

          out = { type: "text", text: block["thinking"].to_s }
          if block["signature"]
            out[:signature] = block["signature"].to_s
            out[:provider_parts] = [
              ProviderCarriers.carrier(destination: "anthropic.messages", index: 0,
                                       kind: "anthropic.content_block", wire: block,
                                       canonical_refs: ["payload.reasoning[0]"])
            ]
          end
          out
        end
        blocks.empty? ? nil : blocks
      end

      def carrier_data?(content)
        content.any? { |block| block["type"] == "thinking" && block["signature"] }
      end

      def text_content_with_carrier(text)
        [{
          type: "text",
          text: text,
          provider_parts: [
            ProviderCarriers.carrier(destination: "anthropic.messages", index: 0,
                                     kind: "anthropic.content_block",
                                     wire: { "type" => "text", "text" => text },
                                     canonical_refs: ["payload.content[0]"])
          ]
        }]
      end

      def tool_use_event(block)
        {
          type: :tool_use,
          payload: Events::ToolUse.new(
            id: block["id"],
            name: block["name"],
            arguments: (block["input"] || {}).transform_keys(&:to_sym)
          ).to_h
        }
      end

      def emit_tokens_consumed(usage)
        Observation.emit(
          :tokens_consumed,
          provider: :anthropic,
          input_tokens: usage[:input_tokens],
          output_tokens: usage[:output_tokens]
        )
      end
    end
  end
end
