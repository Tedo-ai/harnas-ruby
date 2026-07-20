# frozen_string_literal: true

require "json"
require_relative "../providers/anthropic_stream"
require_relative "../providers/openai_stream"
require_relative "../providers/gemini_stream"

module Harnas
  module Conformance
    # Executes the normative raw provider-stream corpus through the production
    # HTTP/SSE adapters. The response chunks are bytes, not pre-normalized
    # Events, so UTF-8 and SSE fragmentation bugs are observable here.
    module ProviderStreamRunner
      SCHEMA_VERSION = "harnas.provider-streams.v1"
      FORBIDDEN_FAILURE_EVENTS = %w[
        assistant_turn_completed assistant_message tool_use
      ].freeze

      Report = Data.define(:cases, :profiles)

      module_function

      def run(spec_root) # rubocop:disable Metrics/AbcSize
        path = File.join(spec_root, "conformance", "provider-streams", "corpus.json")
        corpus = JSON.parse(File.read(path, encoding: "UTF-8"))
        assert(corpus["schema_version"] == SCHEMA_VERSION,
               "unsupported provider-stream schema #{corpus["schema_version"].inspect}")
        profiles = corpus["chunking_profiles"]
        cases = corpus["cases"]
        assert(profiles.is_a?(Hash) && cases.is_a?(Array),
               "provider-stream corpus has invalid top-level shape")

        executions = 0
        cases.each do |fixture|
          fixture.fetch("chunking_profiles").each do |profile_name|
            profile = profiles[profile_name]
            assert(profile.is_a?(Hash),
                   "#{fixture.fetch("id")}: unknown chunking profile #{profile_name.inspect}")
            executions += 1
            run_case(fixture, profile)
          rescue StandardError => e
            raise AssertionError,
                  "#{fixture.fetch("id")}/#{profile_name}: #{e.message}", e.backtrace
          end
        end
        Report.new(cases: cases.length, profiles: executions)
      end

      def run_case(fixture, profile)
        response = fixture.fetch("response")
        http = FixtureHTTP.new(
          status: response.fetch("status"),
          headers: response.fetch("headers"),
          chunks: split_bytes(response.fetch("body").encode(Encoding::UTF_8), profile)
        )
        events = []
        provider = provider_for(fixture.fetch("provider"), http)
        caught = nil
        begin
          provider.call(fixture.fetch("request")) { |event| events << event }
        rescue StandardError => e
          caught = e
        end

        actual_events = normalize_events(events)
        expected = fixture.fetch("expected")
        assert(
          actual_events == expected.fetch("events"),
          "event artifact mismatch\n" \
          "expected: #{JSON.generate(expected.fetch("events"))}\n" \
          "actual:   #{JSON.generate(actual_events)}"
        )
        validate_outcome(fixture.fetch("provider"), expected, caught, actual_events)
      end

      def provider_for(kind, http)
        case kind
        when "anthropic"
          Providers::AnthropicStream.new(
            api_key: "conformance-key",
            endpoint: "https://provider.invalid/anthropic",
            http:
          )
        when "openai"
          Providers::OpenAIStream.new(
            api_key: "conformance-key",
            endpoint: "https://provider.invalid/openai",
            http:
          )
        when "gemini"
          Providers::GeminiStream.new(
            api_key: "conformance-key",
            endpoint_base: "https://provider.invalid/gemini",
            http:
          )
        else
          raise AssertionError, "unsupported provider #{kind.inspect}"
        end
      end

      def validate_outcome(provider, expected, caught, events)
        case expected.fetch("outcome")
        when "success"
          if caught
            assert(caught.nil?,
                   "expected success, got #{caught.class}: #{caught}")
          end
        when "failure"
          assert(!caught.nil?, "expected failure, got success")
          actual_failure = normalize_failure(provider, caught)
          assert(
            actual_failure == expected.fetch("failure"),
            "failure artifact mismatch: expected #{expected.fetch("failure").inspect}, " \
            "got #{actual_failure.inspect}"
          )
          leaked = events.filter_map do |event|
            event["type"] if FORBIDDEN_FAILURE_EVENTS.include?(event["type"])
          end
          assert(leaked.empty?,
                 "failed stream produced durable/completed events: #{leaked.inspect}")
        else
          raise AssertionError, "unsupported expected outcome #{expected["outcome"].inspect}"
        end
      end

      def split_bytes(body, profile)
        sizes = profile["sizes"]
        repeat = profile["repeat"]
        assert(sizes.is_a?(Array) && [true, false].include?(repeat),
               "invalid chunking profile")
        return [body] if sizes.empty?

        chunks = []
        offset = 0
        index = 0
        while offset < body.bytesize
          if index >= sizes.length
            unless repeat
              chunks << body.byteslice(offset..)
              break
            end
            index = 0
          end
          size = sizes[index]
          index += 1
          assert(size.is_a?(Integer) && size.positive?, "invalid chunk size #{size.inspect}")
          chunks << body.byteslice(offset, size)
          offset += size
        end
        chunks.empty? ? [+"".b] : chunks
      end

      def normalize_events(events)
        normalized = JSON.parse(JSON.generate(events))
        normalized.each do |event|
          payload = event.fetch("payload")
          payload["turn_id"] = "<turn_id>" if payload.key?("turn_id")
          payload["error"] = "<provider_failure>" if event["type"] == "assistant_turn_failed"
        end
        normalized
      end

      def normalize_failure(provider, error) # rubocop:disable Metrics/MethodLength
        case error
        when Providers::StreamError
          {
            "kind" => "provider_stream_error",
            "provider" => provider,
            "reason" => "provider_error_frame",
            "provider_error_type" => error.error_type,
            "request_id" => error.request_id,
            "status" => error.status
          }
        when Providers::ProtocolError
          {
            "kind" => "provider_protocol_error",
            "provider" => provider,
            "reason" => error.reason
          }
        when Providers::HTTPError
          {
            "kind" => "http_error",
            "provider" => provider,
            "reason" => "http_status",
            "status" => error.status
          }
        else
          {
            "kind" => "network_error",
            "provider" => provider,
            "reason" => "transport"
          }
        end
      end

      def assert(condition, message)
        raise AssertionError, message unless condition
      end

      class FixtureHTTP
        def initialize(status:, headers:, chunks:)
          @status = status
          @headers = headers
          @chunks = chunks
        end

        def request(_request)
          yield FixtureResponse.new(status: @status, headers: @headers, chunks: @chunks)
        end
      end

      class FixtureResponse
        attr_reader :code

        def initialize(status:, headers:, chunks:)
          @code = status.to_s
          @headers = headers
          @chunks = chunks.map(&:dup)
        end

        def [](name)
          @headers[name] || @headers[name.downcase]
        end

        def read_body(&)
          return @chunks.join unless block_given?

          @chunks.each(&)
          nil
        end
      end
    end
  end
end
