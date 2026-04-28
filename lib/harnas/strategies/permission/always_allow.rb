# frozen_string_literal: true

require "harnas/hooks"
require "harnas/actions/allow"

module Harnas
  module Strategies
    module Permission
      # Permission baseline: always allow any tool_use.
      #
      # ## Arbitrary choices
      #
      # - Hook: :pre_tool_use
      # - Predicate: (none — always fires)
      # - Action: Actions::Allow
      #
      # Useful as a benchmark baseline and as an explicit "I'm
      # choosing to allow all" rather than relying on the no-handler
      # default. Composes cleanly with other permission strategies
      # via any-deny-wins (spec/14-hooks.md R6).
      class AlwaysAllow
        def self.install(session = nil)
          new.install(session&.hooks || Hooks)
        end

        def install(hooks = Hooks)
          handler = method(:on_pre_tool_use)
          hooks.on(:pre_tool_use, handler)
          handler
        end

        def on_pre_tool_use(**_)
          Harnas::Actions::Allow.call
        end
      end
    end
  end
end
