# frozen_string_literal: true

require "harnas/hooks"
require "harnas/actions/allow"
require "harnas/actions/refuse"

module Harnas
  module Strategies
    module Permission
      # Asks a user-supplied callable whether to allow each tool_use.
      # The callable receives the :tool_use Event and returns a
      # truthy value to allow, falsy to deny. Synchronous by design;
      # intended for interactive surfaces (CLI chat) where a human
      # is actually present.
      #
      # ## Arbitrary choices
      #
      # - Hook: :pre_tool_use
      # - Predicate: user callback returns truthy
      # - Action: Actions::Allow or Actions::Refuse
      #
      # The callback-is-the-predicate shape means this strategy is a
      # very thin wrapper — most of the "logic" lives in whatever the
      # caller passes as `prompt:`. That's on purpose: the human is
      # the strategy.
      class HumanApproval
        # Normative default per spec/strategies/permission/human-approval.md.
        DEFAULT_DENIAL_REASON = "human declined"

        def self.install(session = nil, prompt:, denial_reason: DEFAULT_DENIAL_REASON)
          new(prompt: prompt, denial_reason: denial_reason).install(session&.hooks || Hooks)
        end

        def initialize(prompt:, denial_reason: DEFAULT_DENIAL_REASON)
          raise ArgumentError, "prompt must respond to #call(tool_use)" \
            unless prompt.respond_to?(:call)
          raise ArgumentError, "denial_reason must be a String" \
            unless denial_reason.is_a?(String)

          @prompt         = prompt
          @denial_reason  = denial_reason
        end

        def install(hooks = Hooks)
          handler = method(:on_pre_tool_use)
          hooks.on(:pre_tool_use, handler)
          handler
        end

        def on_pre_tool_use(tool_use:, **_)
          if @prompt.call(tool_use)
            Harnas::Actions::Allow.call
          else
            Harnas::Actions::Refuse.call(reason: @denial_reason)
          end
        end
      end
    end
  end
end
