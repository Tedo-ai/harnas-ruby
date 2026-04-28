# frozen_string_literal: true

require "httpx"
require "json"
require_relative "errors"
require_relative "../observation"

module Harnas
  module Providers
    class Anthropic
      ENDPOINT = "https://api.anthropic.com/v1/messages"
      DEFAULT_API_VERSION = "2023-06-01"

      def initialize(api_key:, api_version: DEFAULT_API_VERSION, http: HTTPX)
        @api_key = api_key
        @api_version = api_version
        @http = http
      end

      def call(request)
        Observation.emit(:provider_called, provider: :anthropic, request: request)
        started = monotonic_ms

        begin
          response = @http.post(ENDPOINT, headers: headers, json: request)
          body     = parse_body(response)

          raise HTTPError.new(response.status, body) unless response.status == 200

          Observation.emit(
            :provider_responded,
            provider: :anthropic,
            duration_ms: monotonic_ms - started,
            response: body
          )
          body
        rescue Harnas::Providers::Error => e
          Observation.emit(
            :provider_failed,
            provider: :anthropic,
            duration_ms: monotonic_ms - started,
            error: e
          )
          raise
        end
      end

      private

      def headers
        {
          "x-api-key" => @api_key,
          "anthropic-version" => @api_version,
          "content-type" => "application/json"
        }
      end

      def parse_body(response)
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
