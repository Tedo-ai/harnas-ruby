# frozen_string_literal: true

module Harnas
  module Events
    TOOL_RESULT_APPROVAL_DECISIONS = %w[
      accepted rejected auto_accepted yolo edited_then_accepted
    ].freeze

    # Payload type for a :tool_result Event.
    #
    # The harness has executed a tool and is recording its outcome.
    # Exactly one of `output` or `error` is non-nil; a `:tool_result`
    # either succeeded (output is a String) or failed (error is a
    # String message). The `tool_use_id` correlates this result with
    # the :tool_use Event it fulfills.
    ToolResult = Data.define(:tool_use_id, :output, :error, :approval) do
      def initialize(tool_use_id:, output: nil, error: nil, approval: nil)
        raise ArgumentError, "tool_use_id must be a String"  unless tool_use_id.is_a?(String)
        raise ArgumentError, "tool_use_id must not be empty" if tool_use_id.empty?
        raise ArgumentError, "ToolResult must have exactly one of output or error" \
          unless [output, error].compact.size == 1
        raise ArgumentError, "output must be a String" if output && !output.is_a?(String)
        raise ArgumentError, "error must be a String"  if error  && !error.is_a?(String)

        validate_approval!(approval)

        super
      end

      def to_h
        out = { tool_use_id: tool_use_id, output: output, error: error }
        out[:approval] = approval if approval
        out
      end

      private

      def validate_approval!(approval)
        return if approval.nil?
        raise ArgumentError, "approval must be a Hash" unless approval.is_a?(Hash)

        decision = approval[:decision] || approval["decision"]
        return if TOOL_RESULT_APPROVAL_DECISIONS.include?(decision)

        raise ArgumentError, "approval.decision is invalid"
      end
    end
  end
end
