# frozen_string_literal: true

require "net/http"
require "json"
require "securerandom"
require_relative "errors"
require_relative "stream_support"

module Harnas
  module Providers
    # Fail-closed streaming provider for OpenAI Chat Completions SSE.
    class OpenAIStream
      attr_reader :kind

      DEFAULT_ENDPOINT = "https://api.openai.com/v1/chat/completions"

      def initialize(api_key:, endpoint: DEFAULT_ENDPOINT, authorization: true, http: nil)
        @api_key = api_key
        @endpoint = endpoint
        @authorization = authorization
        @http = http
        @kind = :openai
      end

      def call(request, &emit)
        state = StreamSupport::OpenAIState.new(turn_id: SecureRandom.uuid, emit:)
        state.start
        stream_wire_events(request.merge(stream: true,
                                         stream_options: { include_usage: true }), state)
        state.finish
      rescue StandardError => e
        state&.fail(e)
        raise
      end

      private

      def stream_wire_events(body, state)
        uri = URI(@endpoint)
        request = Net::HTTP::Post.new(uri)
        request["authorization"] = "Bearer #{@api_key}" if @authorization
        request["content-type"] = "application/json"
        request["accept"] = "text/event-stream"
        request.body = JSON.generate(body)
        with_http(uri) do |http|
          http.request(request) do |response|
            ensure_ok(response)
            StreamSupport.consume_sse(response, provider: "openai") { |data| state.data(data) }
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
