# frozen_string_literal: true

require_relative "../observation"
require_relative "../providers/errors"

module Harnas
  module Conformance
    # A provider that returns pre-recorded responses in order. Used by
    # the conformance runner to feed a deterministic stream of
    # provider responses into an agent loop — every implementation of
    # Harnas that claims conformance must produce the same Log when
    # replayed against the same scripted responses.
    #
    # Shape matches the standard Provider contract (spec/02): #call
    # accepts a request Hash and returns a response Hash. The request
    # is ignored here (the conformance fixture decides the cadence).
    class ScriptedProvider
      class Exhausted < StandardError; end

      def initialize(responses:)
        @responses = responses.dup
        @call_count = 0
      end

      def call(request)
        raise Exhausted, "no more scripted responses" if @responses.empty?

        @call_count += 1
        response = @responses.shift
        raise_error(response["error"]) if response.is_a?(Hash) && response.key?("error")

        Observation.emit(:provider_called, provider: :scripted, request: request)
        Observation.emit(
          :provider_responded,
          provider: :scripted, duration_ms: 0, response: response
        )

        response
      end

      attr_reader :call_count

      def remaining_responses
        @responses.size
      end

      private

      def raise_error(error)
        status = error.fetch("status")
        body   = error.fetch("body")
        raise Harnas::Providers::HTTPError.new(status, body)
      end
    end
  end
end
