# frozen_string_literal: true

require "harnas/hooks"
require "harnas/actions/compact"
require "harnas/compaction/helpers"
require "harnas/mutations"
require "harnas/strategies/observation"

module Harnas
  module Strategies
    module Compaction
      # ToolOutputCap: replace oversized :tool_result payloads (and their
      # matching :tool_use) with a summary message carrying a truncated
      # prefix of the output plus a note about the truncation.
      #
      # Selection axis: Targeted (tool_use/tool_result pairs whose result
      # payload exceeds a byte threshold).
      # Replacement axis: PrefixWithNote (keeps a leading slice of the
      # original output; notes the original size and the cap).
      # Trigger axis: PayloadSize.
      #
      # The research synthesis named oversized tool outputs as the single
      # largest driver of runaway context in production harnesses; every
      # surveyed harness converges on some form of aggressive trimming.
      # This strategy is the canonical implementation for that lever.
      #
      # Semantic trade-off: because a :tool_result cannot be replaced
      # with another :tool_result under the current :compact mutation
      # (the mutation synthesizes a :summary, which projects as a
      # user-role message), compacting a tool pair collapses the chain
      # into a user-role summary rather than preserving the tool
      # call structure. For genuinely oversized outputs (tens of KB),
      # this is often what the caller wants — the model does not need
      # to re-see a 50 KB file dump on every subsequent turn. If a
      # deployment needs tool-chain-preserving truncation, a different
      # strategy (operating via a future :tool_output_truncate
      # mutation) is the right vehicle.
      #
      # See spec/strategies/compaction/tool-output-cap.md.
      class ToolOutputCap
        include Harnas::Strategies::Observation

        DEFAULT_MAX_BYTES    = 4096
        DEFAULT_PREFIX_BYTES = 1024
        DEFAULT_SUMMARY_FORMAT =
          "[tool `$TOOL` output capped at $CAP bytes " \
          "(original $ORIGINAL bytes)]\n$PREFIX"

        def self.install(session = nil, max_bytes: DEFAULT_MAX_BYTES,
                         prefix_bytes: DEFAULT_PREFIX_BYTES,
                         summary_format: DEFAULT_SUMMARY_FORMAT)
          new(
            max_bytes: max_bytes,
            prefix_bytes: prefix_bytes,
            summary_format: summary_format
          ).install(session&.hooks || Hooks)
        end

        def initialize(max_bytes:, prefix_bytes:, summary_format:)
          raise ArgumentError, "max_bytes must be a positive Integer" \
            unless max_bytes.is_a?(Integer) && max_bytes.positive?
          raise ArgumentError, "prefix_bytes must be a non-negative Integer <= max_bytes" \
            unless prefix_bytes.is_a?(Integer) && prefix_bytes >= 0 && prefix_bytes <= max_bytes
          raise ArgumentError, "summary_format must be a String" \
            unless summary_format.is_a?(String)

          @max_bytes      = max_bytes
          @prefix_bytes   = prefix_bytes
          @summary_format = summary_format
        end

        def install(hooks = Hooks)
          handler = method(:on_pre_projection)
          hooks.on(:pre_projection, handler)
          handler
        end

        def on_pre_projection(session:)
          observe_strategy(session, name: "Compaction::ToolOutputCap",
                                    hook_point: :pre_projection) do
            run_pre_projection(session)
          end
        end

        def run_pre_projection(session)
          effective = Mutations.apply(session.log)
          tool_result_index = index_tool_uses(session.log)

          oversized_results(effective).each do |result_evt|
            use_seq = tool_result_index[result_evt.payload[:tool_use_id]]
            next if use_seq.nil?

            Harnas::Actions::Compact.call(
              session,
              replaces: [use_seq, result_evt.seq].sort,
              summary: build_summary(session.log, result_evt)
            )
          end
        end

        private

        def oversized_results(effective)
          effective.select do |e|
            e.type == :tool_result && oversized?(e.payload[:output].to_s)
          end
        end

        def oversized?(output)
          output.bytesize > @max_bytes
        end

        def index_tool_uses(log)
          log.each_with_object({}) do |evt, acc|
            acc[evt.payload[:id]] = evt.seq if evt.type == :tool_use
          end
        end

        def build_summary(log, result_evt)
          tool_name = find_tool_name(log, result_evt.payload[:tool_use_id])
          output    = result_evt.payload[:output].to_s
          prefix    = byte_slice(output, @prefix_bytes)

          @summary_format
            .gsub("$TOOL", tool_name)
            .gsub("$CAP", @max_bytes.to_s)
            .gsub("$ORIGINAL", output.bytesize.to_s)
            .gsub("$PREFIX", prefix)
        end

        def find_tool_name(log, tool_use_id)
          use = log.reverse_each.find do |e|
            e.type == :tool_use && e.payload[:id] == tool_use_id
          end
          use&.payload&.fetch(:name, "unknown").to_s
        end

        # UTF-8-safe byte-bounded slice: truncates to at most `n_bytes`
        # bytes without splitting a multibyte character.
        def byte_slice(string, n_bytes)
          return +"" if n_bytes.zero?

          bytes = string.byteslice(0, n_bytes) || +""
          bytes.force_encoding("UTF-8")
          bytes.scrub("")
        end
      end
    end
  end
end
