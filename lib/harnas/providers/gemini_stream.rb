# frozen_string_literal: true

require "net/http"
require "json"
require "securerandom"
require_relative "errors"
require_relative "stream_support"

module Harnas
  module Providers
    # Fail-closed streaming provider for Gemini streamGenerateContent SSE.
    class GeminiStream
      attr_reader :kind

      DEFAULT_ENDPOINT_BASE = "https://generativelanguage.googleapis.com/v1beta/models"

      def initialize(api_key:, endpoint_base: DEFAULT_ENDPOINT_BASE, http: nil)
        @api_key = api_key
        @endpoint_base = endpoint_base
        @http = http
        @kind = :gemini
      end

      def call(request, &emit)
        state = StreamSupport::GeminiState.new(turn_id: SecureRandom.uuid, emit:)
        state.start
        stream_wire_events(request, state)
        state.finish
      rescue StandardError => e
        state&.fail(e)
        raise
      end

      private

      def stream_wire_events(request, state)
        normalized = JSON.parse(JSON.generate(request))
        model = normalized.delete("model")
        raise Error, "Gemini request must include 'model'" if model.to_s.empty?

        uri = URI("#{@endpoint_base}/#{model}:streamGenerateContent?alt=sse")
        http_request = Net::HTTP::Post.new(uri)
        http_request["x-goog-api-key"] = @api_key
        http_request["content-type"] = "application/json"
        http_request["accept"] = "text/event-stream"
        http_request.body = JSON.generate(normalized)
        with_http(uri) do |http|
          http.request(http_request) do |response|
            ensure_ok(response)
            StreamSupport.consume_sse(response, provider: "gemini") { |data| state.data(data) }
          end
        end
      end

      def with_http(uri, &)
        return yield @http if @http

        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", &)
      end

      def ensure_ok(response)
        return if response.code.to_i == 200

        raw = response.read_body
        body = JSON.parse(raw)
        raise HTTPError.new(response.code.to_i, body)
      rescue JSON::ParserError
        raise HTTPError.new(response.code.to_i, { "error" => raw.to_s })
      end
    end
  end
end
