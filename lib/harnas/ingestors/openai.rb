# frozen_string_literal: true

require "json"
require "harnas/events/assistant_message"
require "harnas/events/tool_use"
require "harnas/observation"

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
        usage   = normalize_usage(response["usage"] || {})

        events = [assistant_event(message, stop, usage)]
        Array(message["tool_calls"]).each do |tc|
          events << tool_use_event(tc)
        end

        emit_tokens_consumed(usage)
        events
      end

      private

      def assistant_event(message, stop, usage)
        {
          type: :assistant_message,
          payload: Events::AssistantMessage.new(
            text: message["content"].to_s,
            stop_reason: stop,
            usage: usage,
            reasoning: reasoning_blocks(message)
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
          blocks << { type: "text", text: text } if text.is_a?(String) && !text.empty?
        end
        blocks.empty? ? nil : blocks
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

      def normalize_usage(wire_usage)
        {
          input_tokens: wire_usage["prompt_tokens"] || 0,
          output_tokens: wire_usage["completion_tokens"] || 0
        }
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
