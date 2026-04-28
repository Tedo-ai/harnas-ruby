# frozen_string_literal: true

require "harnas/events/revert"

module Harnas
  module Actions
    # Revert: append a :revert Mutation Event to a Session's Log.
    #
    # Nullifies the effect of an earlier Mutation (a :compact or
    # another :revert) by its seq. The Log stays monotonic; a
    # Projection computed after this Revert behaves as if the
    # targeted Mutation had never been applied.
    #
    # Used by: undo-compaction strategies, retract-last-turn, any
    # strategy that changes its mind about a previous Mutation.
    # See spec/16-actions.md.
    module Revert
      def self.call(session, revokes:)
        session.log.append(
          type: :revert,
          payload: Events::Revert.new(revokes: revokes).to_h
        )
      end
    end
  end
end
