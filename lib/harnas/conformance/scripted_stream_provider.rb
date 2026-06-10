# frozen_string_literal: true

require "harnas/providers/errors"

module Harnas
  module Conformance
    class ScriptedStreamProvider
      class Exhausted < StandardError; end

      def initialize(streams:)
        @streams = streams.dup
      end

      def call(request)
        stream = @streams.shift or raise Exhausted, "no more scripted streams"
        stream = unwrap_expected_stream(stream, request) if stream.is_a?(Hash) && stream.key?("expect_request")
        stream.each do |event|
          if event.key?("error")
            yield failed_event(event.fetch("error"))
            raise_error(event.fetch("error"))
          end
          if event.key?("malformed_frame")
            yield failed_event(event.fetch("malformed_frame"))
            raise_malformed_frame(event.fetch("malformed_frame"))
          end

          yield normalize_event(event)
        end
      end

      private

      def unwrap_expected_stream(entry, request)
        expected = entry.fetch("expect_request")
        actual = normalize(request)
        unless actual == normalize(expected)
          message = "request does not match expected: #{actual.inspect} != " \
                    "#{normalize(expected).inspect}"
          raise Harnas::Providers::FixtureError, message
        end
        entry.fetch("response")
      end

      def normalize(value)
        case value
        when Hash
          value.each_with_object({}) { |(k, v), h| h[k.to_s] = normalize(v) }
        when Array
          value.map { |v| normalize(v) }
        when Symbol
          value.to_s
        else
          value
        end
      end

      def failed_event(error)
        {
          type: :assistant_turn_failed,
          payload: {
            turn_id: error.fetch("turn_id"),
            error: error.fetch("message")
          }
        }
      end

      def raise_error(error)
        raise Harnas::Providers::HTTPError.new(
          error.fetch("status"),
          error.fetch("body")
        )
      end

      def raise_malformed_frame(error)
        raise Harnas::Providers::Error, error.fetch("message")
      end

      def normalize_event(event)
        type = event.fetch("type").to_sym
        {
          type: type,
          payload: normalize_payload(type, deep_symbolize(event.fetch("payload")))
        }
      end

      def normalize_payload(type, payload)
        if %i[assistant_turn_completed assistant_message].include?(type)
          payload[:stop_reason] = payload[:stop_reason].to_sym
        end
        payload
      end

      def deep_symbolize(value)
        case value
        when Hash
          value.each_with_object({}) { |(k, v), h| h[k.to_sym] = deep_symbolize(v) }
        when Array
          value.map { |v| deep_symbolize(v) }
        else
          value
        end
      end
    end
  end
end
