# frozen_string_literal: true

require "harnas/events/assistant_message"
require "harnas/events/tool_use"
require "harnas/observation"
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
          out[:signature] = block["signature"].to_s if block["signature"]
          out
        end
        blocks.empty? ? nil : blocks
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
