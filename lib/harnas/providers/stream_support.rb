# frozen_string_literal: true

require "json"
require_relative "errors"
require_relative "../events/assistant_turn_started"
require_relative "../events/assistant_text_delta"
require_relative "../events/tool_use_begin"
require_relative "../events/tool_use_argument_delta"
require_relative "../events/tool_use_end"
require_relative "../events/assistant_turn_completed"
require_relative "../events/assistant_turn_failed"
require_relative "../events/assistant_message"
require_relative "../events/tool_use"

module Harnas
  module Providers
    module StreamSupport
      module_function

      def consume_sse(response, provider:, &)
        buffer = +"".b
        response.read_body do |chunk|
          buffer << chunk.b
          dispatch_complete_blocks(buffer, provider:, &)
        end
        dispatch_block(buffer, provider:, &) unless buffer.empty?
      end

      def dispatch_complete_blocks(buffer, provider:, &)
        while (match = /\r?\n\r?\n/n.match(buffer))
          frame = buffer.byteslice(0, match.begin(0))
          buffer.replace(buffer.byteslice(match.end(0)..) || +"".b)
          dispatch_block(frame, provider:, &)
        end
      end

      def dispatch_block(block, provider:)
        text = block.dup.force_encoding(Encoding::UTF_8)
        unless text.valid_encoding?
          raise ProtocolError.new(
            provider:, reason: "invalid_utf8", message: "provider stream is not valid UTF-8"
          )
        end
        data_lines = text.lines(chomp: true).filter_map do |line|
          next unless line.start_with?("data:")

          data = line.delete_prefix("data:")
          data.start_with?(" ") ? data[1..] : data
        end
        yield data_lines.join("\n") unless data_lines.empty? || data_lines.all?(&:empty?)
      end

      class State
        attr_reader :provider

        def initialize(provider:, turn_id:, emit:)
          @provider = provider
          @turn_id = turn_id
          @emit = emit
          @text_parts = []
          @stop = :other
          @usage = { input_tokens: 0, output_tokens: 0 }
        end

        def start
          event(:assistant_turn_started,
                Events::AssistantTurnStarted.new(turn_id: @turn_id).to_h)
        end

        def fail(error)
          event(:assistant_turn_failed,
                Events::AssistantTurnFailed.new(
                  turn_id: @turn_id, error: "#{error.class}: #{error.message}"
                ).to_h)
        end

        private

        def emit_text(chunk)
          return if chunk.nil? || chunk.empty?

          @text_parts << chunk
          event(:assistant_text_delta,
                Events::AssistantTextDelta.new(turn_id: @turn_id, chunk:).to_h)
        end

        def emit_completion
          event(:assistant_turn_completed,
                Events::AssistantTurnCompleted.new(
                  turn_id: @turn_id, stop_reason: @stop, usage: @usage
                ).to_h)
          event(:assistant_message,
                Events::AssistantMessage.new(
                  text: @text_parts.join, stop_reason: @stop, usage: @usage
                ).to_h)
        end

        def event(type, payload)
          @emit.call({ type:, payload: })
        end

        def payload(raw)
          parsed = JSON.parse(raw)
          return parsed if parsed.is_a?(Hash)

          protocol!("invalid_frame", "SSE payload must be an object")
        rescue JSON::ParserError => e
          protocol!("invalid_json", "invalid SSE JSON: #{e.message}")
        end

        def protocol!(reason, message)
          raise ProtocolError.new(provider:, reason:, message:)
        end

        def parse_arguments(chunks)
          return {} if chunks.empty?

          parsed = JSON.parse(chunks.join)
          protocol!("invalid_tool_arguments", "tool arguments must be a JSON object") \
            unless parsed.is_a?(Hash)
          parsed.transform_keys(&:to_sym)
        rescue JSON::ParserError => e
          protocol!("invalid_tool_arguments", "tool arguments are not valid JSON: #{e.message}")
        end
      end

      class AnthropicState < State
        STOP_REASONS = %w[end_turn max_tokens tool_use stop_sequence refusal].freeze

        def initialize(turn_id:, emit:)
          super(provider: "anthropic", turn_id:, emit:)
          @tools = {}
          @open_blocks = {}
          @message_started = false
          @message_stopped = false
          @stop_seen = false
        end

        def data(raw) # rubocop:disable Metrics/AbcSize
          item = payload(raw)
          type = item["type"]
          unless type.is_a?(String) && !type.empty?
            protocol!("invalid_frame",
                      "SSE event is missing type")
          end
          if type == "error"
            error = item["error"].is_a?(Hash) ? item["error"] : {}
            error_type = error["type"].to_s
            raise StreamError.new(
              provider:, error_type:, message: error["message"].to_s,
              request_id: item["request_id"].to_s, status: anthropic_error_status(error_type)
            )
          end
          return if type == "ping"

          case type
          when "message_start" then message_start(item)
          when "content_block_start" then block_start(item)
          when "content_block_delta" then block_delta(item)
          when "content_block_stop" then block_stop(item)
          when "message_delta" then message_delta(item)
          when "message_stop" then message_stop
          end
        end

        def finish
          protocol!("missing_start", "stream ended before message_start") unless @message_started
          protocol!("missing_terminal", "stream ended before message_stop") unless @message_stopped
          emit_completion
          @tools.sort.each do |_index, tool|
            event(:tool_use, Events::ToolUse.new(
              id: tool[:id], name: tool[:name], arguments: tool[:arguments] || {}
            ).to_h)
          end
        end

        private

        def message_start(item)
          protocol!("duplicate_start", "duplicate message_start event") if @message_started
          protocol!("invalid_order", "message_start after message_stop") if @message_stopped
          @message_started = true
          merge_usage(item.dig("message", "usage"))
        end

        def block_start(item) # rubocop:disable Metrics/AbcSize
          require_active!("content_block_start")
          index = item["index"].to_i
          protocol!("duplicate_block_start", "duplicate content block index") \
            if @open_blocks.key?(index)
          block = item["content_block"].is_a?(Hash) ? item["content_block"] : {}
          type = block["type"].to_s
          protocol!("invalid_frame", "content block is missing type") if type.empty?
          @open_blocks[index] = type
          return unless type == "tool_use"

          id = block["id"].to_s
          name = block["name"].to_s
          if id.empty? || name.empty?
            protocol!("invalid_tool",
                      "tool_use block requires id and name")
          end
          @tools[index] = { id:, name:, arg_chunks: [] }
          event(:tool_use_begin,
                Events::ToolUseBegin.new(turn_id: @turn_id, tool_use_id: id, name:).to_h)
        end

        def block_delta(item) # rubocop:disable Metrics/AbcSize
          require_active!("content_block_delta")
          index = item["index"].to_i
          block_type = @open_blocks[index]
          protocol!("invalid_order", "content block delta has no open block") unless block_type
          delta = item["delta"].is_a?(Hash) ? item["delta"] : {}
          case delta["type"]
          when "text_delta"
            protocol!("invalid_frame", "text delta arrived for tool block") \
              if block_type == "tool_use"
            emit_text(delta["text"].to_s)
          when "input_json_delta"
            tool = @tools[index]
            protocol!("invalid_frame", "input JSON delta arrived outside tool block") unless tool
            chunk = delta["partial_json"].to_s
            tool[:arg_chunks] << chunk
            event(:tool_use_argument_delta,
                  Events::ToolUseArgumentDelta.new(
                    turn_id: @turn_id, tool_use_id: tool[:id], chunk:
                  ).to_h)
          else
            protocol!("invalid_frame", "unknown content block delta type")
          end
        end

        def block_stop(item)
          require_active!("content_block_stop")
          index = item["index"].to_i
          protocol!("invalid_order", "content block stop has no open block") \
            unless @open_blocks.delete(index)
          tool = @tools[index]
          return unless tool

          tool[:arguments] = parse_arguments(tool[:arg_chunks])
          event(:tool_use_end,
                Events::ToolUseEnd.new(
                  turn_id: @turn_id, tool_use_id: tool[:id], arguments: tool[:arguments]
                ).to_h)
        end

        def message_delta(item)
          require_active!("message_delta")
          stop = item.dig("delta", "stop_reason")
          if stop
            protocol!("duplicate_terminal", "duplicate stop_reason") if @stop_seen
            @stop_seen = true
            @stop = STOP_REASONS.include?(stop) ? stop.to_sym : :other
          end
          merge_usage(item["usage"])
        end

        def message_stop
          protocol!("invalid_order", "message_stop before message_start") unless @message_started
          protocol!("duplicate_terminal", "duplicate message_stop") if @message_stopped
          protocol!("incomplete_block", "message_stop with open content block") \
            unless @open_blocks.empty?
          protocol!("missing_stop_reason", "message_stop without stop_reason") unless @stop_seen
          @message_stopped = true
        end

        def require_active!(type)
          protocol!("invalid_order", "#{type} before message_start") unless @message_started
          protocol!("invalid_order", "#{type} after message_stop") if @message_stopped
        end

        def merge_usage(raw)
          return unless raw.is_a?(Hash)

          @usage[:input_tokens] = raw["input_tokens"] if raw.key?("input_tokens")
          @usage[:output_tokens] = raw["output_tokens"] if raw.key?("output_tokens")
        end

        def anthropic_error_status(type)
          {
            "invalid_request_error" => 400, "authentication_error" => 401,
            "billing_error" => 402, "permission_error" => 403, "not_found_error" => 404,
            "request_too_large" => 413, "rate_limit_error" => 429, "api_error" => 500,
            "timeout_error" => 504, "overloaded_error" => 529
          }.fetch(type, 0)
        end
      end

      class OpenAIState < State
        FINISH_REASONS = {
          "stop" => :end_turn, "length" => :max_tokens, "tool_calls" => :tool_use,
          "function_call" => :tool_use, "content_filter" => :refusal
        }.freeze

        def initialize(turn_id:, emit:)
          super(provider: "openai", turn_id:, emit:)
          @tools = {}
          @finish_seen = false
          @done_seen = false
        end

        def data(raw)
          return done! if raw == "[DONE]"

          protocol!("invalid_order", "data after [DONE]") if @done_seen
          item = payload(raw)
          provider_error!(item) if item["error"].is_a?(Hash)
          merge_usage(item["usage"])
          choice = item.dig("choices", 0)
          return unless choice.is_a?(Hash)

          if choice["delta"].is_a?(Hash)
            protocol!("invalid_order", "delta after finish_reason") if @finish_seen
            handle_delta(choice["delta"])
          end
          handle_finish(choice["finish_reason"]) if choice["finish_reason"]
        end

        def finish
          protocol!("missing_terminal", "stream ended before [DONE]") unless @done_seen
          protocol!("missing_finish_reason", "stream ended without finish_reason") \
            unless @finish_seen
          emit_completion
          @tools.sort.each do |_index, tool|
            event(:tool_use, Events::ToolUse.new(
              id: tool[:id], name: tool[:name], arguments: tool[:arguments]
            ).to_h)
          end
        end

        private

        def done!
          protocol!("duplicate_terminal", "duplicate [DONE] sentinel") if @done_seen
          @done_seen = true
        end

        def provider_error!(item)
          error = item["error"]
          error_type = (error["type"] || error["code"]).to_s
          raise StreamError.new(
            provider:, error_type:, message: error["message"].to_s,
            request_id: item["request_id"].to_s, status: error["status"].to_i
          )
        end

        def merge_usage(raw)
          return unless raw.is_a?(Hash)

          @usage[:input_tokens] = raw["prompt_tokens"] if raw.key?("prompt_tokens")
          @usage[:output_tokens] = raw["completion_tokens"] if raw.key?("completion_tokens")
        end

        def handle_delta(delta) # rubocop:disable Metrics/AbcSize
          emit_text(delta["content"]) if delta["content"].is_a?(String)
          Array(delta["tool_calls"]).each do |wire|
            index = wire["index"].to_i
            tool = @tools[index] ||= { id: nil, name: nil, arg_chunks: [], begun: false }
            tool[:id] = wire["id"] if wire["id"]
            tool[:name] = wire.dig("function", "name") if wire.dig("function", "name")
            if tool[:id] && tool[:name] && !tool[:begun]
              tool[:begun] = true
              event(:tool_use_begin,
                    Events::ToolUseBegin.new(
                      turn_id: @turn_id, tool_use_id: tool[:id], name: tool[:name]
                    ).to_h)
            end
            chunk = wire.dig("function", "arguments")
            next unless chunk.is_a?(String) && !chunk.empty?

            protocol!("invalid_tool", "tool arguments before id and name") unless tool[:begun]
            tool[:arg_chunks] << chunk
            event(:tool_use_argument_delta,
                  Events::ToolUseArgumentDelta.new(
                    turn_id: @turn_id, tool_use_id: tool[:id], chunk:
                  ).to_h)
          end
        end

        def handle_finish(reason)
          protocol!("duplicate_terminal", "duplicate finish_reason") if @finish_seen
          @finish_seen = true
          @stop = FINISH_REASONS.fetch(reason, :other)
          @tools.each_value do |tool|
            protocol!("invalid_tool", "tool call completed without id and name") unless tool[:begun]
            tool[:arguments] = parse_arguments(tool[:arg_chunks])
            event(:tool_use_end,
                  Events::ToolUseEnd.new(
                    turn_id: @turn_id, tool_use_id: tool[:id], arguments: tool[:arguments]
                  ).to_h)
          end
        end
      end

      class GeminiState < State
        FINISH_REASONS = {
          "STOP" => :end_turn, "MAX_TOKENS" => :max_tokens,
          "SAFETY" => :refusal, "RECITATION" => :refusal, "OTHER" => :other
        }.freeze

        def initialize(turn_id:, emit:)
          super(provider: "gemini", turn_id:, emit:)
          @tools = []
          @finish_seen = false
        end

        def data(raw)
          item = payload(raw)
          provider_error!(item) if item["error"].is_a?(Hash)
          protocol!("invalid_order", "data after finishReason") if @finish_seen
          candidate = item.dig("candidates", 0)
          handle_candidate(candidate) if candidate.is_a?(Hash)
          merge_usage(item["usageMetadata"])
        end

        def finish
          protocol!("missing_terminal", "stream ended before finishReason") unless @finish_seen
          emit_completion
          @tools.each do |tool|
            event(:tool_use, Events::ToolUse.new(
              id: tool[:id], name: tool[:name], arguments: tool[:arguments]
            ).to_h)
          end
        end

        private

        def provider_error!(item)
          error = item["error"]
          raise StreamError.new(
            provider:, error_type: (error["status"] || error["type"]).to_s,
            message: error["message"].to_s, request_id: item["request_id"].to_s,
            status: error["code"].to_i
          )
        end

        def handle_candidate(candidate)
          Array(candidate.dig("content", "parts")).each do |part|
            emit_text(part["text"]) if part["text"].is_a?(String)
            emit_function_call(part["functionCall"]) if part["functionCall"].is_a?(Hash)
          end
          return unless candidate["finishReason"]

          protocol!("duplicate_terminal", "duplicate finishReason") if @finish_seen
          @finish_seen = true
          @stop = FINISH_REASONS.fetch(candidate["finishReason"], :other)
        end

        def emit_function_call(call)
          name = call["name"].to_s
          protocol!("invalid_tool", "functionCall requires name") if name.empty?
          arguments = call["args"].is_a?(Hash) ? call["args"].transform_keys(&:to_sym) : {}
          tool = { id: "gemini_fc_#{@tools.size}", name:, arguments: }
          @tools << tool
          event(:tool_use_begin,
                Events::ToolUseBegin.new(
                  turn_id: @turn_id, tool_use_id: tool[:id], name:
                ).to_h)
          event(:tool_use_end,
                Events::ToolUseEnd.new(
                  turn_id: @turn_id, tool_use_id: tool[:id], arguments:
                ).to_h)
        end

        def merge_usage(raw)
          return unless raw.is_a?(Hash)

          @usage[:input_tokens] = raw["promptTokenCount"] if raw.key?("promptTokenCount")
          @usage[:output_tokens] = raw["candidatesTokenCount"] if raw.key?("candidatesTokenCount")
        end
      end
    end
  end
end
