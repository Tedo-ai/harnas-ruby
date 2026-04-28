# frozen_string_literal: true

require "json"
require "harnas/observation"

module Harnas
  module Benchmark
    # Deterministic provider for benchmarking: returns the same
    # response for every call, with usage counts derived from the
    # actual request size (JSON-generated chars / 4).
    #
    # This makes comparisons meaningful: different Strategies produce
    # different REQUEST shapes (the compaction decisions affect what's
    # sent), and input_tokens reflect that directly. The RESPONSE is
    # constant so output-side variance doesn't confound the comparison.
    class CannedProvider
      CHARS_PER_TOKEN = 4

      def initialize(response_text: "ok", stop_reason: "end_turn", provider_name: :canned)
        @response_text = response_text
        @stop_reason   = stop_reason
        @provider_name = provider_name
      end

      def call(request)
        Observation.emit(:provider_called, provider: @provider_name, request: request)
        started = monotonic_ms

        response = {
          "content" => [{ "type" => "text", "text" => @response_text }],
          "stop_reason" => @stop_reason,
          "usage" => {
            "input_tokens" => estimate_tokens(JSON.generate(request)),
            "output_tokens" => estimate_tokens(@response_text)
          }
        }

        Observation.emit(
          :provider_responded,
          provider: @provider_name,
          duration_ms: monotonic_ms - started,
          response: response
        )

        response
      end

      private

      def estimate_tokens(text)
        (text.length.to_f / CHARS_PER_TOKEN).ceil
      end

      def monotonic_ms
        (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).to_i
      end
    end
  end
end
