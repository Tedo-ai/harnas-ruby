# frozen_string_literal: true

module Harnas
  module Events
    # Payload for :tool_use_begin — a tool-use block has started
    # within the current streaming turn. The final arguments are not
    # yet known; they arrive in :tool_use_argument_delta events and
    # are consolidated by :tool_use_end.
    ToolUseBegin = Data.define(:turn_id, :tool_use_id, :name) do
      def initialize(turn_id:, tool_use_id:, name:)
        raise ArgumentError, "turn_id must be a non-empty String" \
          unless turn_id.is_a?(String) && !turn_id.empty?
        raise ArgumentError, "tool_use_id must be a non-empty String" \
          unless tool_use_id.is_a?(String) && !tool_use_id.empty?
        raise ArgumentError, "name must be a non-empty String" \
          unless name.is_a?(String) && !name.empty?

        super
      end
    end
  end
end
