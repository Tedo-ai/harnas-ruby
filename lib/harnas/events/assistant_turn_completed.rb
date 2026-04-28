# frozen_string_literal: true

module Harnas
  module Events
    # Payload for :assistant_turn_completed — the terminating Event
    # of a successfully streamed turn. Carries the normalized
    # stop_reason and usage. The consolidated :assistant_message and
    # :tool_use events the provider emits next are what Projections
    # actually read.
    AssistantTurnCompleted = Data.define(:turn_id, :stop_reason, :usage) do
      def initialize(turn_id:, stop_reason:, usage: {})
        allowed = %i[end_turn max_tokens tool_use stop_sequence refusal other]

        raise ArgumentError, "turn_id must be a non-empty String" \
          unless turn_id.is_a?(String) && !turn_id.empty?
        raise ArgumentError, "stop_reason must be a Symbol" unless stop_reason.is_a?(Symbol)
        unless allowed.include?(stop_reason)
          raise ArgumentError,
                "stop_reason must be one of #{allowed.inspect}, got #{stop_reason.inspect}"
        end
        raise ArgumentError, "usage must be a Hash" unless usage.is_a?(Hash)

        super
      end
    end
  end
end
