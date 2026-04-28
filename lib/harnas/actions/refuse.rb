# frozen_string_literal: true

module Harnas
  module Actions
    # Refuse: produce a decision value denying a hook-gated action.
    #
    # Returned from a :pre_tool_use handler (or any decision-style
    # hook defined in spec/14-hooks.md) to signal that the gated
    # action should not proceed. The AgentLoop's any-deny-wins
    # composition (R6) short-circuits on any handler returning this.
    #
    # Used by: HumanApproval, ClassifierGated, SandboxedExec,
    # TwoTier, and every future permission strategy. See
    # spec/16-actions.md.
    module Refuse
      def self.call(reason: nil)
        { allow: false, reason: reason }
      end
    end
  end
end
