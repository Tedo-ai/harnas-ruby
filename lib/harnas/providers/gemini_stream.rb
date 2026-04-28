# frozen_string_literal: true

require "net/http"
require "json"
require "securerandom"
require_relative "errors"
require_relative "../observation"
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
    # Streaming implementation for Google Gemini's streamGenerateContent
    # endpoint, using ?alt=sse. Each SSE chunk is a complete
    # GenerateContentResponse with incremental candidate content. Tool
    # calls arrive whole within a chunk (functionCall part), not split
    # across deltas, so :tool_use_begin + :tool_use_end fire together
    # with no :tool_use_argument_delta in between — still matches the
    # canonical sequence.
    class GeminiStream
      ENDPOINT_BASE = "https://generativelanguage.googleapis.com/v1beta/models"
      ACTION = "streamGenerateContent"

      FINISH_REASON_MAP = {
        "STOP" => :end_turn,
        "MAX_TOKENS" => :max_tokens,
        "SAFETY" => :refusal,
        "RECITATION" => :refusal,
        "OTHER" => :other
      }.freeze

      def initialize(api_key:)
        @api_key = api_key
      end

      def call(request, &block)
        turn_id = SecureRandom.uuid
        state   = new_turn_state(turn_id)
        yield_event(block, :assistant_turn_started,
                    Events::AssistantTurnStarted.new(turn_id: turn_id).to_h)

        stream_wire_events(request, state, &block)
        yield_completion(state, &block)
      rescue StandardError => e
        yield_event(block, :assistant_turn_failed,
                    Events::AssistantTurnFailed.new(turn_id: turn_id,
                                                    error: "#{e.class}: #{e.message}").to_h)
        raise
      end

      private

      def new_turn_state(turn_id)
        {
          turn_id: turn_id,
          text_parts: [],
          tools: [], # [{ id:, name:, arguments: }]
          stop: :other,
          usage: { input_tokens: 0, output_tokens: 0 }
        }
      end

      def stream_wire_events(request, state, &)
        request = normalize(request)
        model   = request.fetch("model") do
          raise Error, "Gemini request must include 'model'"
        end
        body = request.except("model")

        uri = URI("#{ENDPOINT_BASE}/#{model}:#{ACTION}?alt=sse")
        Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
          req = build_request(uri, body)
          http.request(req) do |response|
            ensure_ok(response)
            consume_sse(response, state, &)
          end
        end
      end

      def build_request(uri, body)
        req = Net::HTTP::Post.new(uri)
        req["x-goog-api-key"] = @api_key
        req["content-type"]   = "application/json"
        req["accept"]         = "text/event-stream"
        req.body = JSON.generate(body)
        req
      end

      def ensure_ok(response)
        return if response.code.to_i == 200

        body = parse_json_or_nil(response.read_body) || { "error" => response.read_body }
        raise HTTPError.new(response.code.to_i, body)
      end

      def consume_sse(response, state, &)
        buffer = +""
        response.read_body do |chunk|
          buffer << chunk
          while (idx = buffer.index("\n\n"))
            event_block = buffer[0...idx]
            buffer      = buffer[(idx + 2)..] || +""
            handle_sse_block(event_block, state, &)
          end
        end
      end

      def handle_sse_block(block_text, state, &)
        data_line = block_text.lines.find { |l| l.start_with?("data: ") }
        return unless data_line

        payload = parse_json_or_nil(data_line.sub(/\Adata: /, "").strip)
        dispatch(payload, state, &) if payload
      end

      def parse_json_or_nil(str)
        JSON.parse(str)
      rescue JSON::ParserError
        nil
      end

      def dispatch(payload, state, &)
        candidate = payload.dig("candidates", 0)
        if candidate
          handle_candidate(candidate, state, &)
          handle_finish(candidate["finishReason"], state) if candidate["finishReason"]
        end

        update_usage(payload["usageMetadata"], state) if payload["usageMetadata"]
      end

      def handle_candidate(candidate, state, &)
        (candidate.dig("content", "parts") || []).each { |part| handle_part(part, state, &) }
      end

      def handle_part(part, state, &block)
        if part["text"] && !part["text"].empty?
          state[:text_parts] << part["text"]
          yield_event(block, :assistant_text_delta,
                      Events::AssistantTextDelta.new(
                        turn_id: state[:turn_id], chunk: part["text"]
                      ).to_h)
        elsif part["functionCall"]
          emit_function_call(part["functionCall"], state, &block)
        end
      end

      def emit_function_call(wire_call, state, &block)
        name      = wire_call["name"]
        arguments = (wire_call["args"] || {}).transform_keys(&:to_sym)
        tool_use_id = "gemini_fc_#{state[:tools].size}"

        state[:tools] << { id: tool_use_id, name: name, arguments: arguments }

        yield_event(block, :tool_use_begin,
                    Events::ToolUseBegin.new(
                      turn_id: state[:turn_id], tool_use_id: tool_use_id, name: name
                    ).to_h)
        yield_event(block, :tool_use_end,
                    Events::ToolUseEnd.new(
                      turn_id: state[:turn_id], tool_use_id: tool_use_id, arguments: arguments
                    ).to_h)
      end

      def handle_finish(wire_finish, state)
        state[:stop] = FINISH_REASON_MAP.fetch(wire_finish, :other)
      end

      def update_usage(wire_usage, state)
        state[:usage][:input_tokens]  =
          wire_usage["promptTokenCount"]     || state[:usage][:input_tokens]
        state[:usage][:output_tokens] =
          wire_usage["candidatesTokenCount"] || state[:usage][:output_tokens]
      end

      def normalize(hash)
        JSON.parse(JSON.generate(hash))
      end

      def yield_completion(state)
        yield({
          type: :assistant_turn_completed,
          payload: Events::AssistantTurnCompleted.new(
            turn_id: state[:turn_id], stop_reason: state[:stop], usage: state[:usage]
          ).to_h
        })

        yield({
          type: :assistant_message,
          payload: Events::AssistantMessage.new(
            text: state[:text_parts].join, stop_reason: state[:stop], usage: state[:usage]
          ).to_h
        })

        state[:tools].each do |tool|
          yield({
            type: :tool_use,
            payload: Events::ToolUse.new(
              id: tool[:id], name: tool[:name], arguments: tool[:arguments]
            ).to_h
          })
        end
      end

      def yield_event(block, type, payload)
        block.call({ type: type, payload: payload })
      end
    end
  end
end
