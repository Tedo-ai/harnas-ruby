# frozen_string_literal: true

require "harnas/log"
require "harnas/hooks"
require "harnas/actions/compact"
require "harnas/compaction/helpers"
require "harnas/events/user_message"
require "harnas/strategies/observation"

module Harnas
  module Strategies
    module Compaction
      # SummaryTail: keep the last `keep_recent` message events; replace
      # everything earlier with an LLM-generated summary. Same Selection
      # axis as MarkerTail (Tail) but Replacement is LLMSummary.
      #
      # Selection axis: Tail (keep-last-N by recency).
      # Replacement axis: LLMSummary (a one-turn round-trip through the
      # caller's Projection + Provider + Ingestor).
      # Trigger axis: MessageCount.
      #
      # Built entirely from spec primitives: Log, Projection, Provider,
      # Ingestor. When the trigger fires, the strategy constructs a
      # sub-Log of the events to compact plus a summarization prompt,
      # projects it, calls the provider, ingests the response, and reads
      # the last assistant_message text out of the sub-Log. Honors
      # spec/17-composition-rules.md R1: no escape-hatch callable.
      #
      # See spec/strategies/compaction/summary-tail.md for the Algorithm,
      # failure modes, and block-strip visualization.
      class SummaryTail
        include Harnas::Strategies::Observation

        DEFAULT_PROMPT = <<~PROMPT.strip
          Summarize the preceding conversation tersely, preserving facts
          the agent will need to continue the work. Prefer specifics
          (names, values, decisions) over generalities. Return only the
          summary text, no preamble.
        PROMPT

        def self.install(session = nil, projection:, provider:, ingestor:,
                         max_messages: 20, keep_recent: 10, prompt: DEFAULT_PROMPT)
          new(
            projection: projection, provider: provider, ingestor: ingestor,
            max_messages: max_messages, keep_recent: keep_recent, prompt: prompt
          ).install(session&.hooks || Hooks)
        end

        def initialize(projection:, provider:, ingestor:,
                       max_messages:, keep_recent:, prompt: DEFAULT_PROMPT)
          raise ArgumentError, "projection must respond to #call(log)" \
            unless projection.respond_to?(:call)
          raise ArgumentError, "provider must respond to #call(request)" \
            unless provider.respond_to?(:call)
          raise ArgumentError, "ingestor must respond to #call(response)" \
            unless ingestor.respond_to?(:call)
          raise ArgumentError, "max_messages must be > keep_recent" \
            unless max_messages.is_a?(Integer) && keep_recent.is_a?(Integer) &&
                   max_messages > keep_recent && keep_recent >= 0

          @projection   = projection
          @provider     = provider
          @ingestor     = ingestor
          @max_messages = max_messages
          @keep_recent  = keep_recent
          @prompt       = prompt
        end

        def install(hooks = Hooks)
          handler = method(:on_pre_projection)
          hooks.on(:pre_projection, handler)
          handler
        end

        def on_pre_projection(session:)
          observe_strategy(session, name: "Compaction::SummaryTail",
                                    hook_point: :pre_projection) do
            run_pre_projection(session)
          end
        end

        def run_pre_projection(session)
          messages = Harnas::Compaction::Helpers.message_events(session.log)
          return if messages.size <= @max_messages

          candidate_seqs = messages.first(messages.size - @keep_recent).map(&:seq)
          safe_seqs = Harnas::Compaction::Helpers.tool_pair_safe_range(
            session.log, candidate_seqs
          )
          return if safe_seqs.empty?

          to_summarize = messages.select { |m| safe_seqs.include?(m.seq) }
          summary = summarize(to_summarize)
          return if summary.empty?

          Harnas::Actions::Compact.call(
            session,
            replaces: safe_seqs,
            summary: summary
          )
        end

        private

        def summarize(events)
          sub_log = build_sub_log(events)
          request = @projection.call(sub_log)
          response = @provider.call(request)
          @ingestor.call(response).each { |args| sub_log.append(**args) }
          last_assistant_text(sub_log)
        end

        def build_sub_log(events)
          sub_log = Harnas::Log.new
          events.each { |e| sub_log.append(type: e.type, payload: e.payload) }
          sub_log.append(
            type: :user_message,
            payload: Harnas::Events::UserMessage.new(text: @prompt).to_h
          )
          sub_log
        end

        def last_assistant_text(log)
          assistant = log.reverse_each.find { |e| e.type == :assistant_message }
          assistant ? assistant.payload[:text].to_s : ""
        end
      end
    end
  end
end
