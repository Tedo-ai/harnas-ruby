# frozen_string_literal: true

module Harnas
  module Events
    # Payload for :tool_use_end — a tool-use block has been fully
    # assembled. `arguments` is the parsed Hash form; subscribers that
    # need the tool-call input read this rather than replaying the
    # :tool_use_argument_delta chunks.
    ToolUseEnd = Data.define(:turn_id, :tool_use_id, :arguments) do
      def initialize(turn_id:, tool_use_id:, arguments:)
        raise ArgumentError, "turn_id must be a non-empty String" \
          unless turn_id.is_a?(String) && !turn_id.empty?
        raise ArgumentError, "tool_use_id must be a non-empty String" \
          unless tool_use_id.is_a?(String) && !tool_use_id.empty?
        raise ArgumentError, "arguments must be a Hash" unless arguments.is_a?(Hash)

        super
      end
    end
  end
end
