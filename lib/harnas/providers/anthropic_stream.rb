# frozen_string_literal: true

require "net/http"
require "json"
require "securerandom"
require_relative "errors"
require_relative "stream_support"

module Harnas
  module Providers
    # Fail-closed streaming provider for Anthropic Messages SSE.
    class AnthropicStream
      attr_reader :kind

      DEFAULT_ENDPOINT = "https://api.anthropic.com/v1/messages"

      def initialize(api_key:, api_version: "2023-06-01", endpoint: DEFAULT_ENDPOINT, http: nil)
        @api_key = api_key
        @api_version = api_version
        @endpoint = endpoint
        @http = http
        @kind = :anthropic
      end

      def call(request, &emit)
        state = StreamSupport::AnthropicState.new(turn_id: SecureRandom.uuid, emit:)
        state.start
        stream_wire_events(request.merge(stream: true), state)
        state.finish
      rescue StandardError => e
        state&.fail(e)
        raise
      end

      private

      def stream_wire_events(body, state)
        uri = URI(@endpoint)
        request = Net::HTTP::Post.new(uri)
        request["x-api-key"] = @api_key
        request["anthropic-version"] = @api_version
        request["content-type"] = "application/json"
        request["accept"] = "text/event-stream"
        request.body = JSON.generate(body)
        with_http(uri) do |http|
          http.request(request) do |response|
            ensure_ok(response)
            StreamSupport.consume_sse(response, provider: "anthropic") { |data| state.data(data) }
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
