# frozen_string_literal: true

require_relative "errors"

module Harnas
  module Providers
    # Decides whether a failed Provider.call should be retried, and if
    # so, after how long. The default policy retries transient HTTP
    # statuses (408, 429, 500, 502, 503, 504) and network-style errors
    # (Errno::*, *Timeout*, etc.) with exponential backoff, up to
    # `max_attempts` total tries. Permanent errors (4xx other than the
    # retryable list, ArgumentError, etc.) abort immediately.
    #
    # Substitute a custom policy by passing one to AgentLoop:
    #
    #   AgentLoop.new(..., retry_policy: my_policy)
    #
    # The interface is one method:
    #
    #   #decide(error, attempt) -> [:retry, delay_ms] | :abort
    #
    # `attempt` is 1-indexed — `attempt == 1` is the first failure
    # (after the first call), `attempt == 2` is the second, etc.
    class RetryPolicy
      DEFAULT_MAX_ATTEMPTS    = 3
      DEFAULT_RETRYABLE_HTTP  = [408, 429, 500, 502, 503, 504].freeze
      DEFAULT_BACKOFF_MS      = ->(attempt) { 250 * (2**(attempt - 1)) }
      DEFAULT_RETRYABLE_CLASS_NAMES = %w[
        Net::OpenTimeout
        Net::ReadTimeout
        Errno::ECONNREFUSED
        Errno::ECONNRESET
        Errno::ETIMEDOUT
        Errno::EHOSTUNREACH
        HTTPX::TimeoutError
        HTTPX::ConnectionError
        HTTPX::ResolveError
      ].freeze

      def initialize(max_attempts: DEFAULT_MAX_ATTEMPTS,
                     retryable_http: DEFAULT_RETRYABLE_HTTP,
                     retryable_class_names: DEFAULT_RETRYABLE_CLASS_NAMES,
                     backoff_ms: DEFAULT_BACKOFF_MS)
        raise ArgumentError, "max_attempts must be >= 1" \
          unless max_attempts.is_a?(Integer) && max_attempts >= 1

        @max_attempts          = max_attempts
        @retryable_http        = Array(retryable_http).to_set
        @retryable_class_names = Array(retryable_class_names).to_set
        @backoff_ms            = backoff_ms
      end

      def decide(error, attempt)
        return :abort if attempt >= @max_attempts
        return :abort unless retryable?(error)

        [:retry, @backoff_ms.call(attempt)]
      end

      def retryable?(error)
        return @retryable_http.include?(error.status) if error.is_a?(HTTPError)

        ancestor_names(error).any? { |n| @retryable_class_names.include?(n) }
      end

      private

      def ancestor_names(error)
        error.class.ancestors.map(&:name).compact
      end
    end
  end
end
