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

    class FixtureError < Error; end
  end
end
