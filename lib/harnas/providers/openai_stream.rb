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
    # Streaming implementation for OpenAI Chat Completions API, using
    # SSE. Yields the canonical delta Events per spec/15-streaming.md,
    # then the consolidated :assistant_turn_completed +
    # :assistant_message + :tool_use Events (S5).
    class OpenAIStream
      attr_reader :kind

      FINISH_REASON_MAP = {
        "stop" => :end_turn,
        "length" => :max_tokens,
        "tool_calls" => :tool_use,
        "function_call" => :tool_use,
        "content_filter" => :refusal
      }.freeze

      def initialize(api_key:, endpoint: "https://api.openai.com/v1/chat/completions",
                     authorization: true)
        @api_key = api_key
        @endpoint = endpoint
        @authorization = authorization
        @kind = :openai
      end

      def call(request, &block)
        turn_id = SecureRandom.uuid
        state   = new_turn_state(turn_id)
        yield_event(block, :assistant_turn_started,
                    Events::AssistantTurnStarted.new(turn_id: turn_id).to_h)

        stream_wire_events(request.merge(stream: true), state, &block)
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
          tools: {}, # index => { id:, name:, arg_chunks: [], emitted_begin: bool }
          stop: :other,
          usage: { input_tokens: 0, output_tokens: 0 }
        }
      end

      def stream_wire_events(body, state, &)
        uri = URI(@endpoint)
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
        req["authorization"] = "Bearer #{@api_key}"
        req.delete("authorization") unless @authorization
        req["content-type"]  = "application/json"
        req["accept"]        = "text/event-stream"
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
          while (idx = buffer.index("\n"))
            line   = buffer[0...idx]
            buffer = buffer[(idx + 1)..] || +""
            handle_sse_line(line.strip, state, &)
          end
        end
      end

      def handle_sse_line(line, state, &)
        return if line.empty? || !line.start_with?("data:")

        payload = line.sub(/\Adata:\s*/, "")
        return if payload == "[DONE]"

        parsed = parse_json_or_nil(payload)
        dispatch(parsed, state, &) if parsed
      end

      def parse_json_or_nil(str)
        JSON.parse(str)
      rescue JSON::ParserError
        nil
      end

      def dispatch(payload, state, &)
        usage = payload["usage"]
        if usage
          state[:usage][:input_tokens]  = usage["prompt_tokens"] || state[:usage][:input_tokens]
          state[:usage][:output_tokens] =
            usage["completion_tokens"] || state[:usage][:output_tokens]
        end

        choice = payload.dig("choices", 0)
        return unless choice

        handle_delta(choice["delta"], state, &) if choice["delta"]
        handle_finish(choice["finish_reason"], state, &) if choice["finish_reason"]
      end

      def handle_delta(delta, state, &block)
        content = delta["content"]
        if content && !content.empty?
          state[:text_parts] << content
          yield_event(block, :assistant_text_delta,
                      Events::AssistantTextDelta.new(
                        turn_id: state[:turn_id], chunk: content
                      ).to_h)
        end

        (delta["tool_calls"] || []).each { |tc| handle_tool_call_delta(tc, state, &block) }
      end

      def handle_tool_call_delta(wire_tool_call, state, &)
        tool = ensure_tool_state(wire_tool_call, state)
        emit_tool_use_begin_if_ready(tool, state, &)
        emit_tool_use_argument_delta_if_any(wire_tool_call, tool, state, &)
      end

      def ensure_tool_state(wire_tool_call, state)
        index = wire_tool_call["index"]
        tool  = state[:tools][index] ||= { arg_chunks: [], emitted_begin: false }
        tool[:id]   = wire_tool_call["id"]                     if wire_tool_call["id"]
        tool[:name] = wire_tool_call.dig("function", "name")   if wire_tool_call.dig("function",
                                                                                     "name")
        tool
      end

      def emit_tool_use_begin_if_ready(tool, state, &block)
        return unless tool[:id] && tool[:name] && !tool[:emitted_begin]

        tool[:emitted_begin] = true
        yield_event(block, :tool_use_begin,
                    Events::ToolUseBegin.new(
                      turn_id: state[:turn_id], tool_use_id: tool[:id], name: tool[:name]
                    ).to_h)
      end

      def emit_tool_use_argument_delta_if_any(wire_tool_call, tool, state, &block)
        arg_chunk = wire_tool_call.dig("function", "arguments")
        return if arg_chunk.nil? || arg_chunk.empty?

        tool[:arg_chunks] << arg_chunk
        yield_event(block, :tool_use_argument_delta,
                    Events::ToolUseArgumentDelta.new(
                      turn_id: state[:turn_id], tool_use_id: tool[:id], chunk: arg_chunk
                    ).to_h)
      end

      def handle_finish(wire_finish, state, &block)
        state[:stop] = FINISH_REASON_MAP.fetch(wire_finish, :other)
        state[:tools].each_value do |tool|
          next unless tool[:id]

          arguments = parse_tool_arguments(tool[:arg_chunks])
          tool[:arguments] = arguments
          yield_event(block, :tool_use_end,
                      Events::ToolUseEnd.new(
                        turn_id: state[:turn_id],
                        tool_use_id: tool[:id],
                        arguments: arguments
                      ).to_h)
        end
      end

      def parse_tool_arguments(chunks)
        joined = chunks.join
        return {} if joined.empty?

        JSON.parse(joined).transform_keys(&:to_sym)
      rescue JSON::ParserError
        {}
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

        state[:tools].each_value do |tool|
          next unless tool[:id]

          yield({
            type: :tool_use,
            payload: Events::ToolUse.new(
              id: tool[:id], name: tool[:name], arguments: tool[:arguments] || {}
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
