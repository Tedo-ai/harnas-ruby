# frozen_string_literal: true

require "harnas/events/tool_result"
require "harnas/observation"

module Harnas
  module Tools
    # Executes a :tool_use Event against a Registry and appends a
    # :tool_result Event to the given Log. Catches StandardError from
    # the tool implementation and records it as a failure ToolResult.
    # Emits :tool_invoked for every execution (success or failure).
    class Runner
      def initialize(registry)
        @registry = registry
      end

      def run(tool_use_event, into_log:)
        payload = tool_use_event.payload
        started = monotonic_ms

        begin
          tool   = @registry[payload[:name]]
          output = tool.call(arguments_for(tool, payload[:arguments] || {}))
          emit(tool_use_event, :ok, monotonic_ms - started)
          into_log.append(
            type: :tool_result,
            payload: Events::ToolResult.new(
              tool_use_id: payload[:id],
              output: output.to_s
            ).to_h
          )
        rescue StandardError => e
          emit(tool_use_event, :error, monotonic_ms - started, e)
          into_log.append(
            type: :tool_result,
            payload: Events::ToolResult.new(
              tool_use_id: payload[:id],
              error: "#{e.class}: #{e.message}"
            ).to_h
          )
        end
      end

      private

      def arguments_for(tool, raw_args)
        case tool.args_key_style
        when :string then raw_args.transform_keys(&:to_s)
        when :symbol then raw_args.transform_keys(&:to_sym)
        else              raw_args
        end
      end

      def emit(tool_use_event, outcome, duration_ms, error = nil)
        Observation.emit(
          :tool_invoked,
          tool_use_id: tool_use_event.payload[:id],
          name: tool_use_event.payload[:name],
          outcome: outcome,
          duration_ms: duration_ms,
          error: error
        )
      end

      def monotonic_ms
        (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).to_i
      end
    end
  end
end
