# frozen_string_literal: true

require "open3"
require "timeout"

module Harnas
  module Strategies
    module Guard
      class Health
        def self.install(session = nil, command:, timeout_seconds: 60, on_failure: "refuse_turn")
          new(
            command: command,
            timeout_seconds: timeout_seconds,
            on_failure: on_failure
          ).install(session&.hooks || Hooks)
        end

        def initialize(command:, timeout_seconds: 60, on_failure: "refuse_turn")
          @command = command
          @timeout_seconds = timeout_seconds.to_i
          @on_failure = on_failure.to_s
          @checks = 0
        end

        def install(hooks = Hooks)
          handler = method(:on_pre_projection)
          hooks.on(:pre_projection, handler)
          handler
        end

        def on_pre_projection(session:, **_)
          @checks += 1
          return if @checks == 1

          result = run_check
          return if result[:success]

          if @on_failure == "warn_only"
            annotate(session, result)
          else
            refuse(session, result)
          end
        end

        private

        def run_check
          stdout = +""
          stderr = +""
          status = nil
          timed_out = false

          begin
            Timeout.timeout(@timeout_seconds) do
              stdout, stderr, status = Open3.capture3(@command)
            end
          rescue Timeout::Error
            timed_out = true
            stderr = "health check timed out after #{@timeout_seconds}s"
          end

          output = [stderr, stdout].reject(&:empty?).join("\n")
          exit_code = timed_out ? nil : status&.exitstatus
          { success: !timed_out && status&.success?, output: output, exit_code: exit_code }
        end

        def refuse(session, result)
          session.log.append(
            type: :runtime_error,
            payload: {
              source: "strategy",
              handler: "guard/health",
              error_class: "Harnas::HealthGuard",
              message: "health_check_failed",
              reason: "health_check_failed",
              output: result[:output],
              exit_code: result[:exit_code],
              terminal: true
            }
          )
        end

        def annotate(session, result)
          session.log.append(
            type: :annotation,
            payload: {
              kind: "guard.health_failed",
              data: { output: result[:output], exit_code: result[:exit_code] }
            }
          )
        end
      end
    end
  end
end
