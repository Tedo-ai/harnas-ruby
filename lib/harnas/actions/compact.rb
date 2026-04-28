# frozen_string_literal: true

require "harnas/events/compact"

module Harnas
  module Actions
    # Compact: append a :compact Mutation Event to a Session's Log.
    #
    # Replaces the given `replaces:` seqs with `summary:` for the
    # purpose of later Projections. The originals stay in the Log
    # (see spec/01-overview.md R4); only the Projection output is
    # reshaped.
    #
    # Used by: every compaction strategy. See spec/16-actions.md.
    module Compact
      def self.call(session, replaces:, summary:)
        session.log.append(
          type: :compact,
          payload: Events::Compact.new(replaces: replaces, summary: summary).to_h
        )
      end
    end
  end
end
