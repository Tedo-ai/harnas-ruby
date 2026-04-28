# frozen_string_literal: true

require "harnas/hooks"
require "harnas/actions/compact"
require "harnas/compaction/helpers"

module Harnas
  module Strategies
    module Compaction
      # MarkerTail: keep the last `keep_recent` message events; replace
      # everything earlier with a fixed marker string. Triggers when the
      # number of message events exceeds `max_messages`.
      #
      # Selection axis: Tail (keep-last-N by recency).
      # Replacement axis: Marker (fixed format string, no information
      # preserved beyond the count).
      # Trigger axis: MessageCount.
      #
      # See spec/strategies/compaction/marker-tail.md for the Algorithm,
      # failure modes, and block-strip visualization.
      #
      # Companion strategy TokenMarkerTail fires on the same Selection
      # + Replacement axes with a TokenEstimate trigger instead of a
      # MessageCount trigger. The two will merge under one class once
      # the Trigger taxonomy lands (see devlog).
      class MarkerTail
        # Normative default per spec/strategies/compaction/marker-tail.md.
        # "$N" is substituted with the decimal count of compacted events.
        DEFAULT_SUMMARY_FORMAT = "[snipped $N earlier messages]"

        def self.install(max_messages: 20, keep_recent: 10,
                         summary_format: DEFAULT_SUMMARY_FORMAT)
          new(
            max_messages: max_messages, keep_recent: keep_recent,
            summary_format: summary_format
          ).install
        end

        def initialize(max_messages:, keep_recent:, summary_format: DEFAULT_SUMMARY_FORMAT)
          raise ArgumentError, "max_messages must be > keep_recent" \
            unless max_messages.is_a?(Integer) && keep_recent.is_a?(Integer) &&
                   max_messages > keep_recent && keep_recent >= 0
          raise ArgumentError, "summary_format must be a String" \
            unless summary_format.is_a?(String)

          @max_messages   = max_messages
          @keep_recent    = keep_recent
          @summary_format = summary_format
        end

        def install
          handler = method(:on_pre_projection)
          Hooks.on(:pre_projection, handler)
          handler
        end

        def on_pre_projection(session:)
          messages = Harnas::Compaction::Helpers.message_events(session.log)
          return if messages.size <= @max_messages

          candidate_seqs = messages.first(messages.size - @keep_recent).map(&:seq)
          safe_seqs = Harnas::Compaction::Helpers.tool_pair_safe_range(
            session.log, candidate_seqs
          )
          return if safe_seqs.empty?

          Harnas::Actions::Compact.call(
            session,
            replaces: safe_seqs,
            summary: @summary_format.gsub("$N", safe_seqs.size.to_s)
          )
        end
      end
    end
  end
end
