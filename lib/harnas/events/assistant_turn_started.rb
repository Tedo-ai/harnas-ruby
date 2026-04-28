# frozen_string_literal: true

module Harnas
  module Events
    # Payload for :assistant_turn_started — the first Event of a
    # streaming provider response. `turn_id` correlates every
    # subsequent delta event in this turn with its terminator
    # (:assistant_turn_completed or :assistant_turn_failed).
    AssistantTurnStarted = Data.define(:turn_id) do
      def initialize(turn_id:)
        raise ArgumentError, "turn_id must be a String"  unless turn_id.is_a?(String)
        raise ArgumentError, "turn_id must not be empty" if turn_id.empty?

        super
      end
    end
  end
end
