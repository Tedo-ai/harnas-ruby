# frozen_string_literal: true

require "harnas/hooks"
require "harnas/actions/compact"
require "harnas/compaction/helpers"
require "harnas/strategies/observation"

module Harnas
  module Strategies
    module Compaction
      # TokenMarkerTail: keep the last `keep_recent` message events;
      # replace everything earlier with a marker. Triggers when the
      # estimated token count of the visible message stream exceeds
      # `max_tokens * threshold`.
      #
      # Selection axis: Tail (keep-last-N by recency).
      # Replacement axis: Marker (fixed format string).
      # Trigger axis: TokenEstimate (percentage of budget).
      #
      # MarkerTail and TokenMarkerTail are the same Selection +
      # Replacement strategy; they differ only on the Trigger axis.
      # They will merge under one class once the Trigger taxonomy
      # lands in a future spec version.
      #
      # See spec/strategies/compaction/token-marker-tail.md for the
      # Algorithm, failure modes, and block-strip visualization.
      class TokenMarkerTail
        include Harnas::Strategies::Observation

        # Normative default per spec/strategies/compaction/token-marker-tail.md.
        # $N, $E, $T substituted with count, estimated tokens, trigger tokens.
        DEFAULT_SUMMARY_FORMAT =
          "[compacted $N earlier messages (~$E tokens -> threshold $T)]"

        def self.install(session = nil, max_tokens: 100_000, threshold: 0.85, keep_recent: 10,
                         summary_format: DEFAULT_SUMMARY_FORMAT)
          new(
            max_tokens: max_tokens, threshold: threshold,
            keep_recent: keep_recent, summary_format: summary_format
          ).install(session&.hooks || Hooks)
        end

        def initialize(max_tokens:, threshold:, keep_recent:,
                       summary_format: DEFAULT_SUMMARY_FORMAT)
          raise ArgumentError, "max_tokens must be a positive Integer" \
            unless max_tokens.is_a?(Integer) && max_tokens.positive?
          raise ArgumentError, "threshold must be a Float in (0.0, 1.0]" \
            unless threshold.is_a?(Numeric) && threshold > 0.0 && threshold <= 1.0
          raise ArgumentError, "keep_recent must be a non-negative Integer" \
            unless keep_recent.is_a?(Integer) && keep_recent >= 0
          raise ArgumentError, "summary_format must be a String" \
            unless summary_format.is_a?(String)

          @max_tokens     = max_tokens
          @threshold      = threshold
          @keep_recent    = keep_recent
          @summary_format = summary_format
        end

        def install(hooks = Hooks)
          handler = method(:on_pre_projection)
          hooks.on(:pre_projection, handler)
          handler
        end

        def on_pre_projection(session:)
          observe_strategy(session, name: "Compaction::TokenMarkerTail",
                                    hook_point: :pre_projection) do
            run_pre_projection(session)
          end
        end

        def run_pre_projection(session)
          messages       = Harnas::Compaction::Helpers.message_events(session.log)
          estimated      = Harnas::Compaction::Helpers.estimate_tokens(messages)
          trigger_tokens = (@max_tokens * @threshold).to_i
          return if estimated <= trigger_tokens

          candidate_seqs = messages.first(messages.size - @keep_recent).map(&:seq)
          safe_seqs = Harnas::Compaction::Helpers.tool_pair_safe_range(
            session.log, candidate_seqs
          )
          return if safe_seqs.empty?

          Harnas::Actions::Compact.call(
            session,
            replaces: safe_seqs,
            summary: @summary_format
                     .gsub("$N", safe_seqs.size.to_s)
                     .gsub("$E", estimated.to_s)
                     .gsub("$T", trigger_tokens.to_s)
          )
        end
      end
    end
  end
end
