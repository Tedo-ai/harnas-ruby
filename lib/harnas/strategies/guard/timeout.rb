# frozen_string_literal: true

module Harnas
  module Strategies
    module Guard
      class Timeout
        def self.install(session = nil, timeout_seconds:)
          new(timeout_seconds: timeout_seconds).install(session&.hooks || Hooks)
        end

        def initialize(timeout_seconds:)
          @timeout_seconds = timeout_seconds.to_f
          @started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          @checks = 0
        end

        def install(hooks = Hooks)
          handler = method(:on_pre_projection)
          hooks.on(:pre_projection, handler)
          handler
        end

        def on_pre_projection(session:, **_)
          @checks += 1
          return if @timeout_seconds.zero? && @checks == 1
          return if elapsed < @timeout_seconds

          session.log.append(
            type: :runtime_error,
            payload: {
              source: "strategy",
              handler: "guard/timeout",
              error_class: "Harnas::TimeoutGuard",
              message: "timeout",
              reason: "timeout",
              terminal: true
            }
          )
        end

        def elapsed
          Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started_at
        end
      end
    end
  end
end
