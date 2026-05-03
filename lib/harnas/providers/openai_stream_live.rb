# frozen_string_literal: true

require "socket"
require "openssl"
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
    # Drop-in alternative to OpenAIStream that reads the SSE response
    # byte-for-byte from a raw TCP+TLS socket instead of using
    # Net::HTTP. Same motivation as AnthropicStreamLive: Ruby's
    # Net::HTTP buffers chunked HTTPS responses at a granularity
    # coarser than individual SSE events, collapsing real streaming
    # into bursts. Reading the socket ourselves keeps event-level
    # granularity — each "data: ..." line dispatches the moment it
    # arrives.
    #
    # Emits the same Event-args Hashes in the same order as
    # OpenAIStream (see spec/15-streaming.md).
    class OpenAIStreamLive # rubocop:disable Metrics/ClassLength
      FINISH_REASON_MAP = {
        "stop" => :end_turn,
        "length" => :max_tokens,
        "tool_calls" => :tool_use,
        "function_call" => :tool_use,
        "content_filter" => :refusal
      }.freeze

      HOST = "api.openai.com"
      PORT = 443
      PATH = "/v1/chat/completions"

      def initialize(api_key:)
        @api_key = api_key
      end

      def call(request, &block)
        turn_id = SecureRandom.uuid
        state   = new_turn_state(turn_id)
        yield_event(block, :assistant_turn_started,
                    Events::AssistantTurnStarted.new(turn_id: turn_id).to_h)

        stream_wire_events(
          request.merge(stream: true, stream_options: { include_usage: true }),
          state, &block
        )
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
          "Authorization: Bearer #{@api_key}",
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
            flush_complete_sse_lines(sse_buffer, state, &)
          end
          socket.readline("\r\n") # consume trailing CRLF
        end
      end

      # OpenAI's SSE is line-oriented: each `data: ...` line is one
      # event. Lines may end in \n or \r\n depending on the server.
      def flush_complete_sse_lines(buffer, state, &)
        while (match = /\r?\n/.match(buffer))
          line = buffer[0...match.pre_match.length]
          buffer.replace(match.post_match || +"")
          handle_sse_line(line.strip, state, &)
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
        tool[:id]   = wire_tool_call["id"] if wire_tool_call["id"]
        tool[:name] = wire_tool_call.dig("function", "name") if wire_tool_call.dig(
          "function", "name"
        )
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
