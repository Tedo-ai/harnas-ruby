# frozen_string_literal: true

require "json"
require "harnas/events/assistant_message"
require "harnas/events/tool_use"
require "harnas/observation"
require "harnas/provider_carriers"
require "harnas/usage"

module Harnas
  module Ingestors
    # Pure function: an OpenAI Chat Completions API wire response to an
    # Array of Event-args Hashes the caller should append to its Log.
    #
    # Produces:
    #   - one :assistant_message event carrying the message content
    #     (empty string when the assistant emitted only tool_calls),
    #     the normalized stop_reason, and the normalized usage
    #   - zero or more :tool_use events, one per tool_calls entry,
    #     in wire order
    class OpenAI
      FINISH_REASON_MAP = {
        "stop" => :end_turn,
        "length" => :max_tokens,
        "tool_calls" => :tool_use,
        "function_call" => :tool_use,
        "content_filter" => :refusal
      }.freeze

      def call(response)
        choice = response.dig("choices", 0)
        raise ArgumentError, "response has no choices" if choice.nil?

        message = choice["message"] || {}
        stop    = FINISH_REASON_MAP.fetch(choice["finish_reason"], :other)
        wire_usage = response["usage"] || {}
        usage = Harnas::Usage.normalize(wire_usage)

        events = [assistant_event(message, stop, wire_usage, response)]
        Array(message["tool_calls"]).each do |tc|
          events << tool_use_event(tc)
        end

        emit_tokens_consumed(usage)
        events
      end

      private

      def assistant_event(message, stop, usage, response)
        if carrier_data?(message)
          text = message["content"].to_s
          payload = {
            text: text,
            content: [{
              type: "text",
              text: text,
              provider_parts: [
                ProviderCarriers.carrier(destination: "openai.chat_completions", index: 0,
                                         kind: "openai.message_content",
                                         wire: { "content" => text },
                                         canonical_refs: ["payload.content[0]"])
              ]
            }],
            stop_reason: stop,
            usage: Harnas::Usage.normalize(usage),
            provider: "openai",
            model: response["model"]
          }
          payload[:reasoning] = reasoning_blocks(message)
          payload[:provider_items] = [
            ProviderCarriers.carrier(destination: "openai.chat_completions", index: 0,
                                     kind: "openai.chat_message", wire: message,
                                     canonical_refs: ["payload.content[0]", "payload.reasoning[0]"])
          ]
          return { type: :assistant_message, payload: payload }
        end
        {
          type: :assistant_message,
          payload: Events::AssistantMessage.new(
            text: message["content"].to_s,
            stop_reason: stop,
            usage: usage,
            reasoning: reasoning_blocks(message),
            provider: "openai",
            model: response["model"]
          ).to_h
        }
      end

      def reasoning_blocks(message)
        blocks = []
        if message["reasoning"].is_a?(String) && !message["reasoning"].empty?
          blocks << { type: "text", text: message["reasoning"] }
        end
        Array(message["reasoning_details"]).each do |detail|
          next unless detail.is_a?(Hash)

          text = detail["text"] || detail["reasoning"] || detail["content"]
          next unless text.is_a?(String) && !text.empty?

          block = { type: "text", text: text }
          if reasoning_detail_carrier_data?(detail)
            block[:provider_parts] = [
              ProviderCarriers.carrier(destination: "openai.chat_completions", index: blocks.length,
                                       kind: "openai.reasoning_detail", wire: detail,
                                       canonical_refs: ["payload.reasoning[0]"])
            ]
          end
          blocks << block
        end
        blocks.empty? ? nil : blocks
      end

      def carrier_data?(message)
        Array(message["reasoning_details"]).any? do |detail|
          detail.is_a?(Hash) && reasoning_detail_carrier_data?(detail)
        end
      end

      def reasoning_detail_carrier_data?(detail)
        detail.keys.any? { |key| !%w[type text reasoning content].include?(key.to_s) }
      end

      def tool_use_event(tool_call)
        fn = tool_call["function"] || {}
        {
          type: :tool_use,
          payload: Events::ToolUse.new(
            id: tool_call["id"].to_s,
            name: fn["name"].to_s,
            arguments: parse_arguments(fn["arguments"])
          ).to_h
        }
      end

      def parse_arguments(raw)
        return {} if raw.nil? || raw.empty?

        parsed = JSON.parse(raw)
        parsed.is_a?(Hash) ? parsed.transform_keys(&:to_sym) : {}
      rescue JSON::ParserError
        {}
      end

      def emit_tokens_consumed(usage)
        Observation.emit(
          :tokens_consumed,
          provider: :openai,
          input_tokens: usage[:input_tokens],
          output_tokens: usage[:output_tokens]
        )
      end
    end
  end
end
