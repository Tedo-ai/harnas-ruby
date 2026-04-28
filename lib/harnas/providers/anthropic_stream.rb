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
    # Streaming implementation for Anthropic Messages API, using SSE.
    # Yields delta Event-args Hashes in the canonical vocabulary
    # defined in spec/15-streaming.md S1–S7. After the stream ends,
    # yields the consolidated :assistant_turn_completed plus the
    # non-streaming :assistant_message and :tool_use Events (S5) so
    # Projections can remain ignorant of the stream.
    class AnthropicStream
      STOP_REASON_MAP = {
        "end_turn" => :end_turn,
        "max_tokens" => :max_tokens,
        "tool_use" => :tool_use,
        "stop_sequence" => :stop_sequence,
        "refusal" => :refusal
      }.freeze

      def initialize(api_key:, api_version: "2023-06-01")
        @api_key      = api_key
        @api_version  = api_version
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
          tools: {}, # index => { id:, name:, arg_chunks: [] }
          stop: :other,
          usage: { input_tokens: 0, output_tokens: 0 }
        }
      end

      def stream_wire_events(body, state, &)
        uri = URI("https://api.anthropic.com/v1/messages")
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
        req["x-api-key"]         = @api_key
        req["anthropic-version"] = @api_version
        req["content-type"]      = "application/json"
        req["accept"]            = "text/event-stream"
        req.body = JSON.generate(body)
        req
      end

      def ensure_ok(response)
        return if response.code.to_i == 200

        body = begin
          JSON.parse(response.read_body)
        rescue StandardError
          { "error" => response.read_body }
        end
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
        case payload["type"]
        when "content_block_start"   then handle_block_start(payload, state, &)
        when "content_block_delta"   then handle_block_delta(payload, state, &)
        when "content_block_stop"    then handle_block_stop(payload, state, &)
        when "message_delta"         then handle_message_delta(payload, state)
        end
      end

      def handle_block_start(payload, state, &block)
        cb = payload["content_block"]
        return unless cb["type"] == "tool_use"

        state[:tools][payload["index"]] = {
          id: cb["id"],
          name: cb["name"],
          arg_chunks: []
        }
        yield_event(block, :tool_use_begin,
                    Events::ToolUseBegin.new(
                      turn_id: state[:turn_id], tool_use_id: cb["id"], name: cb["name"]
                    ).to_h)
      end

      def handle_block_delta(payload, state, &block)
        delta = payload["delta"]
        case delta["type"]
        when "text_delta"
          state[:text_parts] << delta["text"]
          yield_event(block, :assistant_text_delta,
                      Events::AssistantTextDelta.new(
                        turn_id: state[:turn_id], chunk: delta["text"]
                      ).to_h)
        when "input_json_delta"
          tool = state[:tools][payload["index"]]
          return unless tool

          tool[:arg_chunks] << delta["partial_json"]
          yield_event(block, :tool_use_argument_delta,
                      Events::ToolUseArgumentDelta.new(
                        turn_id: state[:turn_id],
                        tool_use_id: tool[:id],
                        chunk: delta["partial_json"]
                      ).to_h)
        end
      end

      def handle_block_stop(payload, state, &block)
        tool = state[:tools][payload["index"]]
        return unless tool

        arguments = parse_tool_arguments(tool[:arg_chunks])
        tool[:arguments] = arguments
        yield_event(block, :tool_use_end,
                    Events::ToolUseEnd.new(
                      turn_id: state[:turn_id],
                      tool_use_id: tool[:id],
                      arguments: arguments
                    ).to_h)
      end

      def parse_tool_arguments(chunks)
        joined = chunks.join
        return {} if joined.empty?

        JSON.parse(joined).transform_keys(&:to_sym)
      rescue JSON::ParserError
        {}
      end

      def handle_message_delta(payload, state)
        if payload["delta"] && payload["delta"]["stop_reason"]
          state[:stop] = STOP_REASON_MAP.fetch(payload["delta"]["stop_reason"], :other)
        end
        return unless payload["usage"]

        state[:usage][:input_tokens]  =
          payload["usage"]["input_tokens"]  || state[:usage][:input_tokens]
        state[:usage][:output_tokens] =
          payload["usage"]["output_tokens"] || state[:usage][:output_tokens]
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
            text: state[:text_parts].join,
            stop_reason: state[:stop],
            usage: state[:usage]
          ).to_h
        })

        state[:tools].each_value do |tool|
          next unless tool[:id]

          yield({
            type: :tool_use,
            payload: Events::ToolUse.new(
              id: tool[:id],
              name: tool[:name],
              arguments: tool[:arguments] || {}
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
