# frozen_string_literal: true

require "digest"
require "json"

module Harnas
  module Strategies
    module Guard
      class Repetition
        def self.install(session = nil, max_consecutive_failures: 3, max_identical_calls: 5,
                         max_consecutive_rejections: 3)
          new(
            max_consecutive_failures: max_consecutive_failures,
            max_identical_calls: max_identical_calls,
            max_consecutive_rejections: max_consecutive_rejections
          ).install(session&.hooks || Hooks)
        end

        def initialize(max_consecutive_failures: 3, max_identical_calls: 5,
                       max_consecutive_rejections: 3)
          @max_consecutive_failures = max_consecutive_failures
          @max_identical_calls = max_identical_calls
          @max_consecutive_rejections = max_consecutive_rejections
          @consecutive_failures = 0
          @consecutive_rejections = 0
          @calls = Hash.new(0)
        end

        def install(hooks = Hooks)
          before = method(:on_pre_tool_use)
          after = method(:on_post_tool_use)
          hooks.on(:pre_tool_use, before)
          hooks.on(:post_tool_use, after)
          after
        end

        def on_pre_tool_use(session:, tool_use:, **_)
          key = call_key(tool_use)
          @calls[key] += 1
          fire!(session, "identical_calls", tool_use, @calls[key]) \
            if @calls[key] >= @max_identical_calls
          nil
        end

        def on_post_tool_use(session:, tool_use:, tool_result:, **_)
          if tool_result&.payload&.fetch(:error, nil)
            @consecutive_failures += 1
            fire!(session, "consecutive_failures", tool_use, @consecutive_failures) \
              if @consecutive_failures >= @max_consecutive_failures
          else
            @consecutive_failures = 0
          end

          if tool_result&.payload&.dig(:approval, :decision) == "rejected"
            @consecutive_rejections += 1
            fire!(session, "consecutive_rejections", tool_use, @consecutive_rejections) \
              if @consecutive_rejections >= @max_consecutive_rejections
          else
            @consecutive_rejections = 0
          end
          nil
        end

        private

        def call_key(tool_use)
          args = JSON.generate(tool_use.payload[:arguments] || {})
          "#{tool_use.payload[:name]}:#{Digest::SHA256.hexdigest(args)}"
        end

        def fire!(session, trigger, tool_use, count)
          session.log.append(
            type: :runtime_error,
            payload: {
              source: "strategy",
              handler: "guard/repetition",
              error_class: "Harnas::RepetitionGuard",
              message: "repetition_guard",
              reason: "repetition_guard",
              trigger: trigger,
              tool: tool_use.payload[:name],
              count: count,
              terminal: true
            }
          )
        end
      end
    end
  end
end
