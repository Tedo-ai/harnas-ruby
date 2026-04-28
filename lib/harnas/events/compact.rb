# frozen_string_literal: true

module Harnas
  module Events
    # Payload type for a :compact Mutation Event.
    #
    # `replaces` lists the seq numbers of earlier Events whose
    # contribution to the Projection should be replaced by `summary`.
    # The summary is emitted as a single synthetic event at the
    # position of the lowest replaced seq; the originals stay in the
    # Log untouched. A Compact may itself be revoked by a later
    # :revert Event referencing the Compact's own seq.
    Compact = Data.define(:replaces, :summary) do
      def initialize(replaces:, summary:)
        unless replaces.is_a?(Array) && replaces.all? { |r| r.is_a?(Integer) && r >= 0 }
          raise ArgumentError, "replaces must be an Array of non-negative Integers"
        end
        raise ArgumentError, "replaces must not be empty" if replaces.empty?
        raise ArgumentError, "summary must be a String"   unless summary.is_a?(String)
        raise ArgumentError, "summary must not be empty"  if summary.empty?

        super
      end
    end
  end
end
