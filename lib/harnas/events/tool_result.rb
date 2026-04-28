# frozen_string_literal: true

module Harnas
  module Events
    # Payload type for a :tool_result Event.
    #
    # The harness has executed a tool and is recording its outcome.
    # Exactly one of `output` or `error` is non-nil; a `:tool_result`
    # either succeeded (output is a String) or failed (error is a
    # String message). The `tool_use_id` correlates this result with
    # the :tool_use Event it fulfills.
    ToolResult = Data.define(:tool_use_id, :output, :error) do
      def initialize(tool_use_id:, output: nil, error: nil)
        raise ArgumentError, "tool_use_id must be a String"  unless tool_use_id.is_a?(String)
        raise ArgumentError, "tool_use_id must not be empty" if tool_use_id.empty?
        raise ArgumentError, "ToolResult must have exactly one of output or error" \
          unless [output, error].compact.size == 1
        raise ArgumentError, "output must be a String" if output && !output.is_a?(String)
        raise ArgumentError, "error must be a String"  if error  && !error.is_a?(String)

        super
      end
    end
  end
end
