# frozen_string_literal: true

module Harnas
  module Actions
    # Allow: produce a decision value permitting a hook-gated action.
    #
    # The decision-style hooks (:pre_tool_use etc.) default to allow
    # when no handler registers or when all handlers return nil
    # (R6 in spec/14-hooks.md). Explicitly returning Actions::Allow
    # is useful when a handler wants to record its decision
    # (observable through Hooks.invoke's returns array) rather than
    # just no-opping.
    #
    # See spec/16-actions.md.
    module Allow
      def self.call
        { allow: true }
      end
    end
  end
end
