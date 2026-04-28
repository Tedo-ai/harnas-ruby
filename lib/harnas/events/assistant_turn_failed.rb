# frozen_string_literal: true

module Harnas
  module Events
    # Payload for :assistant_turn_failed — alternative terminating
    # Event of a streamed turn, used when the stream was interrupted
    # before :assistant_turn_completed could fire. When this event is
    # in the Log, the provider MUST NOT have emitted the consolidated
    # :assistant_message and :tool_use Events for this turn.
    AssistantTurnFailed = Data.define(:turn_id, :error) do
      def initialize(turn_id:, error:)
        raise ArgumentError, "turn_id must be a non-empty String" \
          unless turn_id.is_a?(String) && !turn_id.empty?
        raise ArgumentError, "error must be a non-empty String" \
          unless error.is_a?(String) && !error.empty?

        super
      end
    end
  end
end
