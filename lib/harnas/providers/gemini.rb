# frozen_string_literal: true

require "httpx"
require "json"
require_relative "errors"
require_relative "../observation"

module Harnas
  module Providers
    # Google Gemini provider (generateContent endpoint, v1beta).
    #
    # The request hash MUST include `:model` at the top level; the provider
    # extracts it to build the URL path (which is where Google expects the
    # model identifier) and sends the remaining fields as the JSON body.
    # This is the single shape divergence from Anthropic/OpenAI providers
    # and is documented normatively in spec/02-provider-contract.md.
    class Gemini
      attr_reader :kind

      ENDPOINT_BASE = "https://generativelanguage.googleapis.com/v1beta/models"
      ACTION = "generateContent"

      def initialize(api_key:, http: HTTPX)
        @api_key = api_key
        @http = http
        @kind = :gemini
      end

      def call(request)
        request = normalize(request)
        Observation.emit(:provider_called, provider: :gemini, request: request)
        started = monotonic_ms

        begin
          model, body = prepare_body(request)
          response    = @http.post(endpoint(model), headers: headers, json: body)
          parsed      = parse_body(response)

          raise HTTPError.new(response.status, parsed) unless response.status == 200

          Observation.emit(:provider_responded, provider: :gemini,
                                                duration_ms: monotonic_ms - started,
                                                response: parsed)
          parsed
        rescue Harnas::Providers::Error => e
          Observation.emit(:provider_failed, provider: :gemini,
                                             duration_ms: monotonic_ms - started,
                                             error: e)
          raise
        end
      end

      private

      def prepare_body(request)
        model = request.fetch("model") { raise Error, "Gemini request must include 'model'" }
        [model, request.except("model")]
      end

      def endpoint(model)
        "#{ENDPOINT_BASE}/#{model}:#{ACTION}"
      end

      def headers
        {
          "x-goog-api-key" => @api_key,
          "content-type" => "application/json"
        }
      end

      def parse_body(response)
        JSON.parse(response.body.to_s)
      rescue JSON::ParserError => e
        raise Error, "invalid JSON response: #{e.message}"
      end

      def normalize(hash)
        JSON.parse(JSON.generate(hash))
      end

      def monotonic_ms
        (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).to_i
      end
    end
  end
end
