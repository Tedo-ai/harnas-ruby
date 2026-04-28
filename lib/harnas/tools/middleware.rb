# frozen_string_literal: true

require "harnas/observation"

module Harnas
  module Tools
    # Composable wrappers for tool handlers. Every helper here takes a
    # callable (anything responding to #call(args) -> String) and
    # returns a new callable with the same shape. Wrappers stack
    # trivially: `Middleware.timed(Middleware.logged(handler))`.
    #
    # Two flavors:
    #
    #   Stateless per-wrap helpers (module functions):
    #     .timed   emits :tool_timed observation
    #     .logged  writes a short one-line trace around each call
    #     .retried retries on matching exceptions, with backoff
    #
    #   Stateful wrapper classes (share state across multiple tools):
    #     RateLimiter  token-bucket rate limit across wraps
    #     StaleReadGuard  (in stale_read_guard.rb) file-staleness check
    #                     for read → edit / write round-trips
    #
    # Tool middleware is pure-Ruby composition; it does NOT register
    # anything on Harnas::Hooks. If you want cross-cutting behavior at
    # the harness lifecycle level (per-turn, per-projection, per-tool-
    # use across any tool), use a canonical strategy via Hooks instead.
    module Middleware
      # Stateless: wrap a handler so every call emits a :tool_timed
      # observation event carrying the measured duration in ms.
      def self.timed(handler, name: nil)
        lambda do |args|
          started = now_ms
          begin
            result = handler.call(args)
            emit_timed(name, now_ms - started, outcome: :ok)
            result
          rescue StandardError => e
            emit_timed(name, now_ms - started, outcome: :error, error: e.class.name)
            raise
          end
        end
      end

      # Stateless: wrap a handler so it writes a one-line trace to the
      # given IO (default $stderr) before and after each call. Truncates
      # args and the result preview to keep logs readable.
      def self.logged(handler, name: nil, io: $stderr, preview_bytes: 80)
        lambda do |args|
          io.puts "[tool #{name || "?"}] call args=#{preview(args, preview_bytes)}"
          begin
            result = handler.call(args)
            io.puts "[tool #{name || "?"}] ok   result=#{preview(result, preview_bytes)}"
            result
          rescue StandardError => e
            io.puts "[tool #{name || "?"}] err  #{e.class}: #{e.message}"
            raise
          end
        end
      end

      # Stateless: wrap a handler with retry-on-matching-exception.
      # `attempts` is the total call count (1 = no retry); `on` is the
      # list of exception classes to retry on; `backoff_ms` is a proc
      # `(attempt_index) -> ms` controlling inter-attempt sleep.
      DEFAULT_BACKOFF_MS = ->(i) { 100 * (2**i) }

      def self.retried(handler, attempts: 3, on: [StandardError], backoff_ms: DEFAULT_BACKOFF_MS)
        raise ArgumentError, "attempts must be >= 1" \
          unless attempts.is_a?(Integer) && attempts >= 1

        lambda do |args|
          attempts_left = attempts
          attempt_index = 0
          begin
            handler.call(args)
          rescue *on => e
            attempts_left -= 1
            Observation.emit(
              :tool_retry, attempt: attempt_index + 1, of: attempts, error: e.class.name
            )
            raise if attempts_left.zero?

            sleep_ms(backoff_ms.call(attempt_index))
            attempt_index += 1
            retry
          end
        end
      end

      # Stateful: a token-bucket rate limiter. One instance SHOULD be
      # shared across all tool handlers that belong to the same logical
      # budget (e.g. all HTTP-egressing tools).
      #
      #   limiter = Middleware::RateLimiter.new(per_minute: 10)
      #   fetch   = limiter.wrap(fetch_handler)
      #   shell   = limiter.wrap(shell_handler)
      #
      # A call that would exceed the budget raises RateLimitExceeded.
      class RateLimiter
        class RateLimitExceeded < StandardError; end

        def initialize(per_minute:)
          raise ArgumentError, "per_minute must be a positive Integer" \
            unless per_minute.is_a?(Integer) && per_minute.positive?

          @budget = per_minute
          @window = 60.0
          @timestamps = []
        end

        def wrap(handler)
          outer = self
          lambda do |args|
            outer.send(:admit!)
            handler.call(args)
          end
        end

        private

        def admit!
          now = monotonic_s
          @timestamps.reject! { |t| t < now - @window }
          if @timestamps.size >= @budget
            raise RateLimitExceeded, "rate limit: #{@budget} per minute"
          end

          @timestamps << now
        end

        def monotonic_s
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end

      # ---- helpers ----

      def self.now_ms
        (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).to_i
      end
      private_class_method :now_ms

      def self.sleep_ms(duration_ms)
        sleep(duration_ms / 1000.0) if duration_ms.positive?
      end
      private_class_method :sleep_ms

      def self.emit_timed(name, duration_ms, outcome:, error: nil)
        Observation.emit(
          :tool_timed,
          name: name, duration_ms: duration_ms, outcome: outcome, error: error
        )
      end
      private_class_method :emit_timed

      def self.preview(value, limit)
        str = value.is_a?(String) ? value : value.inspect
        str.length > limit ? "#{str[0, limit]}…" : str
      end
      private_class_method :preview
    end
  end
end
