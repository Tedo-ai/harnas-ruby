# frozen_string_literal: true

require "json"
require_relative "errors"
require_relative "../observation"

module Harnas
  module Providers
    # Replays a recorded conformance fixture. The fixture directory must
    # contain `request.json` and `response.json` as produced by running a
    # real smoke script with `--record DIR`.
    #
    # In strict mode (the default), `call` raises FixtureError unless the
    # incoming request deep-equals the recorded request (after JSON
    # normalization, so symbol/string key differences don't matter). Strict
    # mode catches regressions where a caller's request shape has drifted
    # from the recorded wire format. Turn it off when using a fixture as a
    # generic response-shape source rather than a canonical replay.
    class Mock
      attr_reader :fixture_path, :strict, :recorded_request, :recorded_response

      def initialize(fixture_path:, strict: true)
        @fixture_path = fixture_path
        @strict = strict
        load_fixtures!
      end

      def call(request)
        Observation.emit(:provider_called, provider: :mock, request: request)
        started = monotonic_ms

        begin
          if strict && normalize(request) != @recorded_request
            raise FixtureError,
                  "request does not match recorded fixture at #{fixture_path}"
          end

          Observation.emit(
            :provider_responded,
            provider: :mock,
            duration_ms: monotonic_ms - started,
            response: @recorded_response
          )
          @recorded_response
        rescue Harnas::Providers::Error => e
          Observation.emit(
            :provider_failed,
            provider: :mock,
            duration_ms: monotonic_ms - started,
            error: e
          )
          raise
        end
      end

      private

      def load_fixtures!
        req_path = File.join(fixture_path, "request.json")
        res_path = File.join(fixture_path, "response.json")

        unless File.exist?(req_path) && File.exist?(res_path)
          raise FixtureError,
                "fixture files missing at #{fixture_path} " \
                "(expected request.json and response.json)"
        end

        @recorded_request  = JSON.parse(File.read(req_path))
        @recorded_response = JSON.parse(File.read(res_path))
      rescue JSON::ParserError => e
        raise FixtureError, "invalid JSON in fixture at #{fixture_path}: #{e.message}"
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
