# frozen_string_literal: true

module Harnas
  module Conformance
    class ScriptedStreamProvider
      class Exhausted < StandardError; end

      def initialize(streams:)
        @streams = streams.dup
      end

      def call(_request)
        stream = @streams.shift or raise Exhausted, "no more scripted streams"
        stream.each { |event| yield normalize_event(event) }
      end

      private

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
