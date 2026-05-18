# frozen_string_literal: true

require "httpx"
require "json"
require_relative "errors"
require_relative "../observation"

module Harnas
  module Providers
    class Ollama
      DEFAULT_BASE_URL = "http://localhost:11434/v1"

      def initialize(base_url: ENV.fetch("OLLAMA_BASE_URL", DEFAULT_BASE_URL), http: HTTPX)
        @endpoint = chat_endpoint(base_url)
        @http = http
      end

      def call(request)
        Observation.emit(:provider_called, provider: :ollama, request: request)
        started = monotonic_ms

        begin
          response = @http.post(@endpoint, headers: headers, json: request)
          body = parse_body(response)
          raise HTTPError.new(response.status, body) unless response.status == 200

          Observation.emit(
            :provider_responded,
            provider: :ollama,
            duration_ms: monotonic_ms - started,
            response: body
          )
          body
        rescue Harnas::Providers::Error => e
          Observation.emit(
            :provider_failed,
            provider: :ollama,
            duration_ms: monotonic_ms - started,
            error: e
          )
          raise
        end
      end

      private

      def chat_endpoint(base_url)
        base = base_url.to_s.delete_suffix("/")
        return "#{base}/chat/completions" if base.end_with?("/v1")

        "#{base}/v1/chat/completions"
      end

      def headers
        {
          "content-type" => "application/json",
          "accept" => "application/json"
        }
      end

      def parse_body(response)
        raise Error, response.to_s unless response.respond_to?(:body)

        JSON.parse(response.body.to_s)
      rescue JSON::ParserError => e
        raise Error, "invalid JSON response: #{e.message}"
      end

      def monotonic_ms
        (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).to_i
      end
    end
  end
end
