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
    # Drop-in alternative to GeminiStream that reads the SSE response
    # byte-for-byte from a raw TCP+TLS socket instead of using
    # Net::HTTP. Same motivation as AnthropicStreamLive and
    # OpenAIStreamLive.
    #
    # Gemini's SSE uses "data: ...\n\n" blocks like Anthropic, but
    # function calls arrive whole inside a single content-part chunk
    # (no argument_delta streaming from the wire) — we still emit the
    # canonical begin+end pair for consistency.
    class GeminiStreamLive # rubocop:disable Metrics/ClassLength
      FINISH_REASON_MAP = {
        "STOP" => :end_turn,
        "MAX_TOKENS" => :max_tokens,
        "SAFETY" => :refusal,
        "RECITATION" => :refusal,
        "OTHER" => :other
      }.freeze

      HOST = "generativelanguage.googleapis.com"
      PORT = 443

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
          tools: [],
          stop: :other,
          usage: { input_tokens: 0, output_tokens: 0 }
        }
      end

      def stream_wire_events(request, state, &)
        normalized = JSON.parse(JSON.generate(request))
        model      = normalized.fetch("model") { raise Error, "Gemini request missing 'model'" }
        body       = normalized.except("model")
        path       = "/v1beta/models/#{model}:streamGenerateContent?alt=sse"

        socket = connect_tls
        begin
          send_request(socket, path, body)
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

      def send_request(socket, path, body)
        payload = JSON.generate(body)
        lines = [
          "POST #{path} HTTP/1.1",
          "Host: #{HOST}",
          "User-Agent: harnas/0.1",
          "Accept: text/event-stream",
          "Content-Type: application/json",
          "x-goog-api-key: #{@api_key}",
          "Content-Length: #{payload.bytesize}",
          "Connection: close",
          ""
        ]
        socket.write("#{lines.join("\r\n")}\r\n")
        socket.write(payload)
      end

      def read_headers!(socket)
        code, headers = parse_response_headers(socket)
        trace("status=#{code} headers=#{headers.inspect}")
        raise_http_error(socket, code, headers) unless code == "200"
        unless headers["transfer-encoding"].to_s.downcase.include?("chunked")
          raise Error, "expected chunked transfer-encoding from Gemini, got " \
                       "#{headers["transfer-encoding"].inspect} " \
                       "(content-length=#{headers["content-length"].inspect})"
        end
        headers
      end

      def parse_response_headers(socket)
        status_line = socket.readline("\r\n")
        _, code, = status_line.split(" ", 3)
        headers = {}
        loop do
          line = socket.readline("\r\n")
          break if line == "\r\n" || line.empty?

          k, v = line.chomp.split(": ", 2)
          headers[k.downcase] = v if k && v
        end
        [code, headers]
      end

      def raise_http_error(socket, code, headers)
        body_preview = read_error_body(socket, headers)
        parsed = begin
          JSON.parse(body_preview)
        rescue StandardError
          { "raw" => body_preview }
        end
        raise HTTPError.new(code.to_i, parsed)
      end

      def read_error_body(socket, headers)
        cl = headers["content-length"].to_i
        if cl.positive?
          socket.read(cl).to_s
        else
          +"" # chunked error body rare; keep it short
        end
      rescue StandardError
        +""
      end

      def consume_chunked_sse(socket, state, &)
        sse_buffer = +""
        loop { break unless read_one_chunk?(socket, sse_buffer, state, &) }
        trace("buffer after loop (#{sse_buffer.bytesize} bytes): #{sse_buffer.inspect}")
      end

      def read_one_chunk?(socket, sse_buffer, state, &)
        size_line = socket.readline("\r\n")
        trace("size_line=#{size_line.inspect}")
        size = size_line.to_s.strip.to_i(16)
        trace("chunk size=#{size}")
        return false if size.zero?

        remaining = size
        while remaining.positive?
          data = socket.readpartial([remaining, 4096].min)
          trace("read #{data.bytesize} bytes of chunk")
          remaining -= data.bytesize
          sse_buffer << data
          flush_complete_sse_events(sse_buffer, state, &)
        end
        trailer = socket.readline("\r\n")
        trace("trailer=#{trailer.inspect}")
        true
      end

      def trace(msg)
        return unless ENV["HARNAS_TRACE_GEMINI"]

        warn "[gemini] #{msg}"
      end

      # SSE events are separated by a blank line. Gemini sends that
      # blank line as CRLFCRLF (\r\n\r\n); Anthropic and OpenAI send
      # it as LFLF (\n\n). Match either.
      def flush_complete_sse_events(buffer, state, &)
        while (match = /\r?\n\r?\n/.match(buffer))
          event_block = buffer[0...match.pre_match.length]
          buffer.replace(match.post_match || +"")
          handle_sse_block(event_block, state, &)
        end
      end

      def handle_sse_block(block_text, state, &)
        trace_sse_block(block_text)
        data_line = block_text.lines.find { |l| l.start_with?("data: ") }
        return unless data_line

        payload = parse_json_or_nil(data_line.sub(/\Adata: /, "").strip)
        trace_parsed(payload)
        dispatch(payload, state, &) if payload
      end

      def trace_sse_block(block_text)
        return unless ENV["HARNAS_TRACE_GEMINI"]

        warn "[gemini sse] --- raw block ---"
        warn block_text
        warn "[gemini sse] --- end block ---"
      end

      def trace_parsed(payload)
        return unless ENV["HARNAS_TRACE_GEMINI"]

        warn "[gemini sse] parsed: #{payload.inspect}"
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
        name        = wire_call["name"]
        arguments   = (wire_call["args"] || {}).transform_keys(&:to_sym)
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
          wire_usage["promptTokenCount"] || state[:usage][:input_tokens]
        state[:usage][:output_tokens] =
          wire_usage["candidatesTokenCount"] || state[:usage][:output_tokens]
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
