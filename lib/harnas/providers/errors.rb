# frozen_string_literal: true

require "json"

module Harnas
  module Providers
    class Error < StandardError; end

    class HTTPError < Error
      attr_reader :status, :body

      MESSAGE_BODY_LIMIT = 500

      def initialize(status, body)
        @status = status
        @body = body
        super("HTTP #{status}: #{format_body_excerpt(body)}")
      end

      private

      def format_body_excerpt(body)
        rendered =
          case body
          when Hash, Array then JSON.generate(body)
          else body.to_s
          end
        rendered.length > MESSAGE_BODY_LIMIT ? "#{rendered[0, MESSAGE_BODY_LIMIT]}…" : rendered
      end
    end

    class StreamError < Error
      attr_reader :provider, :error_type, :request_id, :status

      def initialize(provider:, error_type:, message:, request_id: "", status: 0)
        @provider = provider.to_s
        @error_type = error_type.to_s
        @request_id = request_id.to_s
        @status = status.to_i
        request = @request_id.empty? ? "" : " (request_id=#{@request_id})"
        super("#{@provider} stream error #{@error_type}#{request}: #{message}")
      end
    end

    class ProtocolError < Error
      attr_reader :provider, :reason

      def initialize(provider:, reason:, message:)
        @provider = provider.to_s
        @reason = reason.to_s
        super("#{@provider} stream protocol error: #{message}")
      end
    end

    class FixtureError < Error; end
  end
end
