# frozen_string_literal: true

require_relative "event"
require_relative "observation"

module Harnas
  # Resolves Mutation Events (:compact, :revert) against a Log,
  # producing the "effective" event stream that Projections render.
  #
  # The Log itself is never modified. Mutations are pure functions of
  # the event sequence: given the same Log, `apply` always produces
  # the same effective stream. This is R3 + R5 from
  # spec/01-overview.md materialized in code.
  module Mutations
    MUTATION_TYPES = %i[compact revert].freeze

    # Returns an Array<Event> in which:
    #   - Mutation Events themselves are removed
    #   - Each non-revoked :compact's `replaces` seqs are removed
    #     and a synthesized :summary Event takes the place of the
    #     lowest replaced seq (carrying the compact's own seq/id)
    #   - A :revert nullifies an earlier mutation by seq; chains
    #     compose monotonically
    def self.apply(log)
      state  = analyze(log)
      result = effective(log, state)

      Observation.emit(
        :mutation_applied,
        log_size: log.size,
        effective_size: result.size,
        applied_count: state[:summary_at].size
      )

      result
    end

    def self.analyze(log)
      mutations = log.select { |e| MUTATION_TYPES.include?(e.type) }
      revoked   = revoked_seqs(mutations)
      compacts  = mutations.select { |e| e.type == :compact && !revoked.include?(e.seq) }

      {
        shadowed: compacts.flat_map { |c| c.payload[:replaces] }.to_set,
        summary_at: compacts.to_h { |c| [c.payload[:replaces].min, c] }
      }
    end
    private_class_method :analyze

    def self.effective(log, state)
      log.each_with_object([]) do |evt, acc|
        next if MUTATION_TYPES.include?(evt.type)

        if state[:summary_at].key?(evt.seq)
          acc << synthesize_summary(state[:summary_at][evt.seq])
        elsif state[:shadowed].include?(evt.seq)
          # shadowed by an active compaction — skip
        else
          acc << evt
        end
      end
    end
    private_class_method :effective

    def self.synthesize_summary(compact)
      Event.new(
        seq: compact.seq,
        id: compact.id,
        type: :summary,
        payload: { text: compact.payload[:summary] }
      )
    end
    private_class_method :synthesize_summary

    def self.revoked_seqs(mutations)
      mutations.select { |e| e.type == :revert }
               .to_set { |e| e.payload[:revokes] }
    end
    private_class_method :revoked_seqs
  end
end
