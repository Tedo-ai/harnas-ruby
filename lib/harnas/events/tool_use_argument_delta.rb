# frozen_string_literal: true

module Harnas
  module Events
    # Payload for :tool_use_argument_delta — one chunk of streamed
    # tool-call input (a partial JSON fragment, as it arrives on the
    # wire). Consumers that need the assembled arguments read the
    # terminating :tool_use_end event's `arguments` field.
    ToolUseArgumentDelta = Data.define(:turn_id, :tool_use_id, :chunk) do
      def initialize(turn_id:, tool_use_id:, chunk:)
        raise ArgumentError, "turn_id must be a non-empty String" \
          unless turn_id.is_a?(String) && !turn_id.empty?
        raise ArgumentError, "tool_use_id must be a non-empty String" \
          unless tool_use_id.is_a?(String) && !tool_use_id.empty?
        raise ArgumentError, "chunk must be a String" unless chunk.is_a?(String)

        super
      end
    end
  end
end
