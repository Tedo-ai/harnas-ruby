# frozen_string_literal: true

require "json"
require "securerandom"
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

      def run(tool_use_event, into_log:) # rubocop:disable Metrics/AbcSize
        payload = tool_use_event.payload
        started = monotonic_ms

        begin
          tool   = @registry[payload[:name]]
          return run_spawn_agent(tool_use_event, into_log: into_log) \
            if tool.handler == "harnas.builtin.spawn_agent"

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

      def run_spawn_agent(tool_use_event, into_log:)
        payload = tool_use_event.payload
        args = payload[:arguments] || {}
        task = value_for(args, :task)
        raise ArgumentError, "missing required argument: task" if task.to_s.empty?

        spawn_id = "spn_#{SecureRandom.uuid}"
        child_session_id = "ses_#{SecureRandom.uuid}"
        append_spawn_agent_event(into_log, tool_use_event, args, spawn_id, child_session_id, task)
        append_spawn_agent_result(into_log, payload[:id], spawn_id, child_session_id)
        emit(tool_use_event, :ok, 0)
      end

      def append_spawn_agent_event(log, tool_use_event, args, spawn_id, child_session_id, task)
        log.append(
          type: :agent_spawn,
          payload: {
            spawn_id: spawn_id,
            child_session_id: child_session_id,
            spawned_by_event_id: tool_use_event.id,
            spawn_mode: "new",
            task: task,
            capabilities: { inherit: true, overrides: spawn_agent_overrides(args) },
            join_policy: value_for(args, :join_policy) || "async",
            metadata: spawn_agent_metadata(args),
            retry_of_spawn_id: nil
          }
        )
      end

      def append_spawn_agent_result(log, tool_use_id, spawn_id, child_session_id)
        log.append(
          type: :tool_result,
          payload: Events::ToolResult.new(
            tool_use_id: tool_use_id,
            output: JSON.generate(
              spawn_id: spawn_id,
              child_session_id: child_session_id,
              status: "spawned"
            )
          ).to_h
        )
      end

      def spawn_agent_metadata(args)
        {}.tap do |metadata|
          metadata[:label] = value_for(args, :label) if value_for(args, :label)
          metadata[:role] = value_for(args, :role) if value_for(args, :role)
        end
      end

      def spawn_agent_overrides(args)
        tools_deny = value_for(args, :tools_deny)
        tools_deny ? { tools_deny: tools_deny } : {}
      end

      def value_for(args, key)
        args[key] || args[key.to_s]
      end

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
