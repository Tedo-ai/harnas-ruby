# frozen_string_literal: true

require "socket"
require "openssl"
require "uri"
require "json"
require "securerandom"

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
    # Drop-in alternative to AnthropicStream that reads the SSE response
    # byte-for-byte from a raw TCP+TLS socket instead of using
    # Net::HTTP. Net::HTTP with chunked-encoded HTTPS on Ruby 3.x can
    # hold back SSE events until the kernel/SSL buffer flushes a larger
    # block, which collapses real streaming into big bursts. Reading
    # the socket ourselves with readline/readpartial gives us
    # event-level granularity: each SSE event dispatches the moment
    # its terminating blank line arrives.
    #
    # Emits the same Event-args Hashes in the same order as
    # AnthropicStream (see spec/15-streaming.md).
    class AnthropicStreamLive # rubocop:disable Metrics/ClassLength
      STOP_REASON_MAP = {
        "end_turn" => :end_turn,
        "max_tokens" => :max_tokens,
        "tool_use" => :tool_use,
        "stop_sequence" => :stop_sequence,
        "refusal" => :refusal
      }.freeze

      HOST = "api.anthropic.com"
      PORT = 443
      PATH = "/v1/messages"

      def initialize(api_key:, api_version: "2023-06-01")
        @api_key     = api_key
        @api_version = api_version
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
                    Events::AssistantTurnFailed.new(
                      turn_id: turn_id, error: "#{e.class}: #{e.message}"
                    ).to_h)
        raise
      end

      private

      def new_turn_state(turn_id)
        {
          turn_id: turn_id,
          text_parts: [],
          tools: {},
          stop: :other,
          usage: { input_tokens: 0, output_tokens: 0 }
        }
      end

      def stream_wire_events(body, state, &)
        socket = connect_tls
        begin
          send_request(socket, body)
          read_headers!(socket)
          consume_chunked_sse(socket, state, &)
        ensure
          begin
            socket.close
          rescue StandardError
            nil
          end
        end
      end

      def connect_tls
        tcp = TCPSocket.new(HOST, PORT)
        tcp.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
        ssl = OpenSSL::SSL::SSLSocket.new(tcp, ssl_context)
        ssl.sync_close = true
        ssl.hostname   = HOST
        ssl.connect
        ssl
      end

      def ssl_context
        ctx = OpenSSL::SSL::SSLContext.new
        ctx.verify_mode = OpenSSL::SSL::VERIFY_PEER
        ctx.set_params
        ctx
      end

      def send_request(socket, body)
        payload = JSON.generate(body)
        lines = [
          "POST #{PATH} HTTP/1.1",
          "Host: #{HOST}",
          "User-Agent: harnas/0.1",
          "Accept: text/event-stream",
          "Content-Type: application/json",
          "x-api-key: #{@api_key}",
          "anthropic-version: #{@api_version}",
          "Content-Length: #{payload.bytesize}",
          "Connection: close",
          ""
        ]
        socket.write("#{lines.join("\r\n")}\r\n")
        socket.write(payload)
      end

      def read_headers!(socket)
        status_line = socket.readline("\r\n")
        _, code, = status_line.split(" ", 3)
        headers  = {}
        loop do
          line = socket.readline("\r\n")
          break if line == "\r\n" || line.empty?

          k, v = line.chomp.split(": ", 2)
          headers[k.downcase] = v if k && v
        end

        unless code == "200"
          body_preview = read_error_body(socket, headers)
          parsed = begin
            JSON.parse(body_preview)
          rescue StandardError
            { "raw" => body_preview }
          end
          raise HTTPError.new(code.to_i, parsed)
        end

        unless headers["transfer-encoding"].to_s.downcase.include?("chunked")
          raise Error, "expected chunked transfer-encoding, got " \
                       "#{headers["transfer-encoding"].inspect}"
        end

        headers
      end

      def read_error_body(socket, headers)
        cl = headers["content-length"].to_i
        cl.positive? ? socket.read(cl).to_s : +""
      rescue StandardError
        +""
      end

      # Anthropic uses chunked transfer-encoding. Each chunk:
      #   <hex size>\r\n
      #   <size bytes of body>
      #   \r\n
      # Terminated by a zero-length chunk.
      def consume_chunked_sse(socket, state, &)
        sse_buffer = +""
        loop do
          size_line = socket.readline("\r\n").to_s.strip
          size      = size_line.to_i(16)
          break if size.zero?

          remaining = size
          while remaining.positive?
            data = socket.readpartial([remaining, 4096].min)
            remaining -= data.bytesize
            sse_buffer << data
            flush_complete_sse_events(sse_buffer, state, &)
          end
          socket.readline("\r\n") # consume trailing CRLF
        end
      end

      def flush_complete_sse_events(buffer, state, &)
        while (match = /\r?\n\r?\n/.match(buffer))
          event_block = buffer[0...match.pre_match.length]
          buffer.replace(match.post_match || +"")
          handle_sse_block(event_block, state, &)
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
        when "content_block_start" then handle_block_start(payload, state, &)
        when "content_block_delta" then handle_block_delta(payload, state, &)
        when "content_block_stop"  then handle_block_stop(payload, state, &)
        when "message_delta"       then handle_message_delta(payload, state)
        end
      end

      def handle_block_start(payload, state, &block)
        cb = payload["content_block"]
        return unless cb["type"] == "tool_use"

        state[:tools][payload["index"]] = {
          id: cb["id"], name: cb["name"], arg_chunks: []
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
                      turn_id: state[:turn_id], tool_use_id: tool[:id],
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
