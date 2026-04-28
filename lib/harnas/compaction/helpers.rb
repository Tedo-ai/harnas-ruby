# frozen_string_literal: true

require "harnas/mutations"

module Harnas
  module Compaction
    # Shared utilities for compaction strategies. A strategy is just
    # plain Ruby that runs at :pre_projection and appends a :compact
    # Mutation Event when it decides to; these helpers are opt-in
    # conveniences the reference strategies use, and that any custom
    # strategy SHOULD call rather than reinventing.
    #
    # Helpers live at the family (Compaction) level, not at the
    # strategy level — the same utilities are useful across MarkerTail,
    # TokenMarkerTail, SummaryTail, and future strategies.
    module Helpers
      # Event types that count as "real" conversational messages.
      # :summary events (produced by previous compactions) are
      # deliberately excluded so strategies that use this filter as
      # their threshold signal remain idempotent across repeated
      # :pre_projection invocations.
      MESSAGE_TYPES = %i[user_message assistant_message tool_use tool_result].freeze

      # Effective events (post-Mutations.apply) filtered to the real
      # message types. The canonical starting point for most
      # compaction strategies' "what's visible?" inspection.
      def self.message_events(log)
        Mutations.apply(log).select { |e| MESSAGE_TYPES.include?(e.type) }
      end

      # Cheap, provider-agnostic token-count estimate for a collection
      # of events. Uses a 4-chars-per-token heuristic — deliberately
      # NOT a real tokenizer. Strategies that need precise counts
      # should not use this and should carry their own tokenizer.
      def self.estimate_tokens(events)
        events.sum { |e| estimate_event_tokens(e) }
      end

      def self.estimate_event_tokens(event)
        text = extract_text(event)
        (text.length / 4.0).ceil
      end

      # Trims a candidate list of seqs to guarantee we never orphan a
      # :tool_use from its :tool_result (or vice versa) by compacting
      # one half of a tool-call pair without the other. Returns a
      # sorted Array of seqs guaranteed safe to compact.
      #
      # Orphan scenarios this guards against:
      #   - :tool_use in candidates, its :tool_result NOT → Projection
      #     would emit a tool_result referencing a tool_use that's
      #     been replaced by a summary. Every provider rejects this.
      #   - :tool_result in candidates, its :tool_use NOT → Projection
      #     would emit an orphaned tool_use whose result is missing,
      #     forcing the model to re-run or fail.
      #
      # On asymmetry, both halves are removed from the safe set — the
      # conservative choice, preserving pair integrity at the cost of
      # keeping slightly more context than the strategy requested.
      def self.tool_pair_safe_range(log, candidate_seqs)
        candidate_set = candidate_seqs.to_set
        safe          = candidate_seqs.to_set

        tool_pairs(log).each do |use_seq, result_seq|
          use_in    = candidate_set.include?(use_seq)
          result_in = candidate_set.include?(result_seq)
          next if use_in == result_in

          safe.delete(use_seq)
          safe.delete(result_seq)
        end

        safe.sort
      end

      def self.extract_text(event)
        case event.type
        when :user_message, :assistant_message
          event.payload[:text].to_s
        when :tool_use
          "#{event.payload[:name]} #{event.payload[:arguments]}"
        when :tool_result
          (event.payload[:output] || event.payload[:error]).to_s
        else
          ""
        end
      end
      private_class_method :extract_text

      def self.tool_pairs(log)
        use_seqs    = {}
        result_seqs = {}
        log.each do |event|
          case event.type
          when :tool_use    then use_seqs[event.payload[:id]]             = event.seq
          when :tool_result then result_seqs[event.payload[:tool_use_id]] = event.seq
          end
        end
        use_seqs.filter_map { |id, use_seq| [use_seq, result_seqs[id]] if result_seqs[id] }
      end
      private_class_method :tool_pairs
    end
  end
end
