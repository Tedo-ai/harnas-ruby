# frozen_string_literal: true

module Harnas
  module Events
    # Payload type for a :revert Mutation Event.
    #
    # `revokes` is the seq number of an earlier Mutation Event (a
    # :compact, or another :revert). When applied, the referenced
    # Mutation's effect on later Projections is undone — the Log
    # itself is unchanged. A :revert may itself be revoked by a
    # later :revert; the chain composes monotonically.
    Revert = Data.define(:revokes) do
      def initialize(revokes:)
        unless revokes.is_a?(Integer) && revokes >= 0
          raise ArgumentError, "revokes must be a non-negative Integer"
        end

        super
      end
    end
  end
end
