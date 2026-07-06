# frozen_string_literal: true

module Harnas
  module Actions
    # RequestApproval: produce the third pre_tool_use decision shape
    # (spec/07-permission.md R7) holding a tool_use un-executed for
    # async approval. Composition per tool_use is
    # Refuse > RequestApproval > Allow; any pending_approval verdict
    # pauses the dispatch batch atomically (R8) and the run ends with
    # the :awaiting_approval outcome. See spec/16-actions.md.
    module RequestApproval
      def self.call(reason: nil, requested_by: nil)
        { pending_approval: true, reason: reason, requested_by: requested_by }
      end
    end
  end
end
