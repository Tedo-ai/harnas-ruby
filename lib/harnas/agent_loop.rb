# frozen_string_literal: true

require "harnas/hooks"
require "harnas/capabilities"
require "harnas/observation"
require "harnas/events/provider_error"
require "harnas/events/tool_result"
require "harnas/providers/retry_policy"
require "harnas/usage"

module Harnas
  # The reusable agent loop: drives Log → Projection → Provider →
  # Ingestor → (optional tool dispatch) → loop, invoking the canonical
  # lifecycle Hook Points at each step (see spec/14-hooks.md).
  #
  # Terminates when the assistant's stop_reason is not :tool_use, when
  # there are no pending :tool_use Events, or when max_turns is reached.
  class AgentLoop # rubocop:disable Metrics/ClassLength
    DEFAULT_MAX_TURNS = 10
    STREAM_DELTA_TYPES = %i[
      assistant_text_delta
      tool_use_argument_delta
    ].freeze
    STREAM_OBSERVATION_TYPES = %i[
      assistant_turn_started
      assistant_text_delta
      tool_use_begin
      tool_use_argument_delta
      tool_use_end
      assistant_turn_completed
      assistant_turn_failed
    ].freeze

    def initialize(session:, projection:, runner: nil, max_turns: DEFAULT_MAX_TURNS, # rubocop:disable Metrics/ParameterLists
                   provider: nil, ingestor: nil, stream_provider: nil,
                   retry_policy: nil, on_stream_event: nil, provider_kind: nil)
      raise ArgumentError, "provide either stream_provider: or (provider: and ingestor:)" \
        if stream_provider.nil? && (provider.nil? || ingestor.nil?)

      @session         = session
      @projection      = projection
      @provider        = provider
      @ingestor        = ingestor
      @stream_provider = stream_provider
      @runner          = runner
      @max_turns       = max_turns
      @retry_policy    = retry_policy || Harnas::Providers::RetryPolicy.new
      @on_stream_event = on_stream_event
      @provider_kind   = provider_kind
      @current_request = {}
      @event_scan_index = 0
      @fulfilled_tool_use_ids = Set.new
      @latest_tool_results = {}
    end

    # rubocop:disable Metrics/BlockLength, Metrics/MethodLength
    def run
      Observation.with_current(@session.observation) do
        @session.hooks.invoke(:session_started, session: @session)
        reason = :max_turns_reached

        @max_turns.times do |turn|
          stop_reason = run_turn(turn)

          if %i[provider_failed runtime_failed].include?(stop_reason)
            reason = stop_reason
            break
          end

          if stop_reason != :tool_use
            reason = :end_turn
            break
          end

          dispatched, awaiting = dispatch_pending_tools
          if awaiting
            reason = :awaiting_approval
            break
          end
          if terminal_runtime_error?
            reason = :runtime_failed
            break
          end
          if dispatched.empty?
            reason = :no_pending_tools
            break
          end
        rescue Hooks::TurnFailed
          reason = :runtime_failed
          break
        end

        @session.hooks.invoke(:session_ended, session: @session, reason: reason)
        reason
      end
    end
    # rubocop:enable Metrics/BlockLength, Metrics/MethodLength

    private

    def run_turn(turn)
      @session.hooks.invoke(:turn_started, session: @session, turn: turn)

      @session.hooks.invoke(:pre_projection, session: @session)
      return :runtime_failed if terminal_runtime_error?

      request = @projection.call(@session.log)
    rescue CapabilityMismatchError => e
      append_runtime_error(reason: "capability_mismatch", message: e.message)
      :runtime_failed
    else
      @session.hooks.invoke(:post_projection, session: @session, request: request)

      ok = call_provider_with_retry(request)
      return :provider_failed unless ok

      last_assistant = @session.log.reverse_each.find { |e| e.type == :assistant_message }
      stop_reason    = last_assistant.payload[:stop_reason]

      @session.hooks.invoke(:turn_ended, session: @session, turn: turn, stop_reason: stop_reason)
      stop_reason
    end

    # Drives one provider call, retrying transient failures per the
    # configured RetryPolicy. Each failed attempt appends a
    # :provider_error event with terminal: false; the final failed
    # attempt (or the only attempt for an immediately-fatal error)
    # appends one with terminal: true. Returns true on eventual
    # success, false if all attempts fail.
    def call_provider_with_retry(request)
      attempt = 1
      loop do
        run_one_provider_attempt(request)
        return true
      rescue Hooks::TurnFailed
        raise
      rescue StandardError => e
        decision = @retry_policy.decide(e, attempt)
        if decision == :abort
          append_provider_error(e, attempt: attempt, terminal: true)
          return false
        end

        _, delay_ms = decision
        append_provider_error(e, attempt: attempt, terminal: false)
        sleep(delay_ms / 1000.0) if delay_ms.positive?
        attempt += 1
      end
    end

    def run_one_provider_attempt(request)
      if @stream_provider
        run_streaming_turn(request)
      else
        run_buffered_turn(request)
      end
    end

    def run_buffered_turn(request)
      @session.hooks.invoke(:pre_provider_call, session: @session, request: request)
      response = @provider.call(request)
      @session.hooks.invoke(:post_provider_call, session: @session, response: response)

      @session.hooks.invoke(:pre_ingest, session: @session, response: response)
      events = @ingestor.call(response)
      events.each do |event|
        stamp_assistant_identity!(event, request)
        @session.log.append(**event)
      end
      @session.hooks.invoke(:post_ingest, session: @session, events: events)
    end

    def run_streaming_turn(request)
      @session.hooks.invoke(:pre_provider_call, session: @session, request: request)
      @current_request = request
      begin
        @stream_provider.call(request) do |event|
          handle_stream_event(event)
        end
      ensure
        @current_request = {}
      end
      @session.hooks.invoke(:post_provider_call, session: @session, response: nil)
    end

    def handle_stream_event(event)
      type = event.fetch(:type)
      if STREAM_OBSERVATION_TYPES.include?(type)
        observed = Event.new(seq: -1, id: "stream", type: type, payload: event.fetch(:payload))
        @session.observation.emit(:stream_event, event: observed)
        @on_stream_event&.call(observed) if STREAM_DELTA_TYPES.include?(type)
      else
        stamp_assistant_identity!(event, @current_request)
        @session.log.append(**event)
      end
    end

    def stamp_assistant_identity!(event, request)
      return unless event[:type] == :assistant_message

      payload = event[:payload]
      payload[:provider] = provider_kind_for_error.to_s
      payload[:model] ||= request[:model] || request["model"]
      payload[:usage] = Harnas::Usage.normalize(payload[:usage] || {})
    end

    def append_provider_error(error, attempt:, terminal:)
      provider_kind = provider_kind_for_error
      status        = error.respond_to?(:status) ? error.status : nil
      @session.log.append(
        type: :provider_error,
        payload: Events::ProviderError.new(
          provider: provider_kind,
          status: status,
          error_class: error.class.name.to_s,
          message: error.message.to_s,
          attempt: attempt,
          terminal: terminal
        ).to_h
      )
    end

    def append_runtime_error(reason:, message:)
      @session.log.append(
        type: :runtime_error,
        payload: {
          source: "projection",
          handler: projection_kind_for_error,
          error_class: "CapabilityMismatchError",
          message: message,
          reason: reason,
          terminal: true
        }
      )
    end

    def projection_kind_for_error
      explicit_kind(@projection)
    end

    def provider_kind_for_error
      return @provider_kind.to_sym if @provider_kind && !@provider_kind.to_s.empty?

      explicit_kind(@stream_provider || @provider).to_sym
    end

    def explicit_kind(object)
      return "unknown" unless object

      kind = object.respond_to?(:provider_kind) ? object.provider_kind : nil
      kind = object.kind if (kind.nil? || kind.to_s.empty?) && object.respond_to?(:kind)
      kind.to_s.empty? ? "unknown" : kind.to_s
    end

    # Two-pass dispatch (spec/07-permission.md R7-R8): first compose every
    # pending tool_use's :pre_tool_use decision; any pending_approval verdict
    # (on a tool_use not already refused) pauses the batch atomically — no
    # tool_use executes, only :approval_requested Events are appended, and the
    # run ends with the :awaiting_approval outcome.
    def dispatch_pending_tools
      pending = pending_tool_uses
      decisions_list = pending.map do |tool_use|
        @session.hooks.invoke(:pre_tool_use, session: @session, tool_use: tool_use)
      end
      requests = approval_requests(pending, decisions_list)
      if requests.any?
        requests.each { |tool_use, decision| append_approval_request(tool_use, decision) }
        return [pending, true]
      end
      pending.each_with_index do |tool_use, index|
        dispatch_one_tool(tool_use, decisions_list[index])
      end
      [pending, false]
    end

    def approval_requests(pending, decisions_list)
      pending.each_with_index.filter_map do |tool_use, index|
        decisions = decisions_list[index]
        next if decisions.any? { |d| d.is_a?(Hash) && d[:allow] == false }

        decision = decisions.find { |d| d.is_a?(Hash) && d[:pending_approval] == true }
        [tool_use, decision] if decision
      end
    end

    def append_approval_request(tool_use_event, decision)
      @session.log.append(
        type: :approval_requested,
        payload: {
          tool_use_id: payload_value(tool_use_event, :id),
          reason: decision[:reason],
          requested_by: decision[:requested_by]
        }
      )
    end

    def terminal_runtime_error?
      @session.log.any? { |event| event.type == :runtime_error && event.payload[:terminal] }
    end

    def dispatch_one_tool(tool_use_event, decisions)
      denied = decisions.find { |d| d.is_a?(Hash) && d[:allow] == false }

      if denied
        append_denial(tool_use_event, denied[:reason])
      else
        @runner&.run(tool_use_with_argument_overrides(tool_use_event, decisions),
                     into_log: @session.log,
                     session: @session)
      end
      remember_new_tool_results

      @session.hooks.invoke(
        :post_tool_use,
        session: @session,
        tool_use: tool_use_event,
        tool_result: @latest_tool_results[payload_value(tool_use_event, :id)],
        denied: !denied.nil?
      )
    end

    def tool_use_with_argument_overrides(tool_use_event, decisions)
      override = decisions.find do |decision|
        decision.is_a?(Hash) && decision[:arguments].is_a?(Hash)
      end
      return tool_use_event unless override

      Event.new(
        seq: tool_use_event.seq,
        id: tool_use_event.id,
        type: tool_use_event.type,
        payload: tool_use_event.payload.merge(arguments: override[:arguments])
      )
    end

    def pending_tool_uses
      candidates = []
      scan_new_events do |event|
        if event.type == :tool_result
          remember_tool_result(event)
        elsif event.type == :tool_use
          candidates << event
        end
      end
      candidates.reject { |event| @fulfilled_tool_use_ids.include?(payload_value(event, :id)) }
    end

    def remember_new_tool_results
      scan_new_events { |event| remember_tool_result(event) if event.type == :tool_result }
    end

    def scan_new_events
      while @event_scan_index < @session.log.size
        event = @session.log.at(@event_scan_index)
        @event_scan_index += 1
        yield event
      end
    end

    def remember_tool_result(event)
      tool_use_id = payload_value(event, :tool_use_id)
      return if tool_use_id.nil?

      @fulfilled_tool_use_ids << tool_use_id
      @latest_tool_results[tool_use_id] = event
    end

    def payload_value(event, key)
      event.payload[key] || event.payload[key.to_s]
    end

    def append_denial(tool_use_event, reason)
      reason ||= "no reason given"
      @session.log.append(
        type: :tool_result,
        payload: Events::ToolResult.new(
          tool_use_id: tool_use_event.payload[:id],
          error: "denied by hook: #{reason}",
          approval: { decision: "rejected", rule_matched: reason, applied_diff: nil }
        ).to_h
      )
    end
  end
end
