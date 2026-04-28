# frozen_string_literal: true

require "harnas/hooks"
require "harnas/events/provider_error"
require "harnas/events/tool_result"
require "harnas/providers/retry_policy"

module Harnas
  # The reusable agent loop: drives Log → Projection → Provider →
  # Ingestor → (optional tool dispatch) → loop, invoking the canonical
  # lifecycle Hook Points at each step (see spec/14-hooks.md).
  #
  # Terminates when the assistant's stop_reason is not :tool_use, when
  # there are no pending :tool_use Events, or when max_turns is reached.
  class AgentLoop
    DEFAULT_MAX_TURNS = 10

    def initialize(session:, projection:, runner: nil, max_turns: DEFAULT_MAX_TURNS, # rubocop:disable Metrics/ParameterLists
                   provider: nil, ingestor: nil, stream_provider: nil,
                   retry_policy: nil)
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
    end

    def run
      Hooks.invoke(:session_started, session: @session)
      reason = :max_turns_reached

      @max_turns.times do |turn|
        stop_reason = run_turn(turn)

        if stop_reason == :provider_failed
          reason = :provider_failed
          break
        end

        if stop_reason != :tool_use
          reason = :end_turn
          break
        end

        if dispatch_pending_tools.empty?
          reason = :no_pending_tools
          break
        end
      end

      Hooks.invoke(:session_ended, session: @session, reason: reason)
      reason
    end

    private

    def run_turn(turn)
      Hooks.invoke(:turn_started, session: @session, turn: turn)

      Hooks.invoke(:pre_projection, session: @session)
      request = @projection.call(@session.log)
      Hooks.invoke(:post_projection, session: @session, request: request)

      ok = call_provider_with_retry(request)
      return :provider_failed unless ok

      last_assistant = @session.log.reverse_each.find { |e| e.type == :assistant_message }
      stop_reason    = last_assistant.payload[:stop_reason]

      Hooks.invoke(:turn_ended, session: @session, turn: turn, stop_reason: stop_reason)
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
      Hooks.invoke(:pre_provider_call, session: @session, request: request)
      response = @provider.call(request)
      Hooks.invoke(:post_provider_call, session: @session, response: response)

      Hooks.invoke(:pre_ingest, session: @session, response: response)
      events = @ingestor.call(response)
      events.each { |e| @session.log.append(**e) }
      Hooks.invoke(:post_ingest, session: @session, events: events)
    end

    def run_streaming_turn(request)
      Hooks.invoke(:pre_provider_call, session: @session, request: request)
      @stream_provider.call(request) { |event| @session.log.append(**event) }
      Hooks.invoke(:post_provider_call, session: @session, response: nil)
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

    def provider_kind_for_error
      live = @stream_provider || @provider
      class_name = live.class.name.to_s
      if    class_name.include?("Anthropic") then :anthropic
      elsif class_name.include?("OpenAI")    then :openai
      elsif class_name.include?("Gemini")    then :gemini
      else  :unknown
      end
    end

    def dispatch_pending_tools
      pending = pending_tool_uses
      pending.each { |tu| dispatch_one_tool(tu) }
      pending
    end

    def dispatch_one_tool(tool_use_event)
      decisions = Hooks.invoke(:pre_tool_use, session: @session, tool_use: tool_use_event)
      denied    = decisions.find { |d| d.is_a?(Hash) && d[:allow] == false }

      if denied
        append_denial(tool_use_event, denied[:reason])
      else
        @runner&.run(tool_use_event, into_log: @session.log)
      end

      Hooks.invoke(
        :post_tool_use,
        session: @session,
        tool_use: tool_use_event,
        tool_result: matching_tool_result(tool_use_event),
        denied: !denied.nil?
      )
    end

    def matching_tool_result(tool_use_event)
      @session.log.reverse_each.find do |e|
        e.type == :tool_result && e.payload[:tool_use_id] == tool_use_event.payload[:id]
      end
    end

    def pending_tool_uses
      fulfilled = @session.log.each_with_object(Set.new) do |e, set|
        set << e.payload[:tool_use_id] if e.type == :tool_result
      end
      @session.log.select do |e|
        e.type == :tool_use && !fulfilled.include?(e.payload[:id])
      end
    end

    def append_denial(tool_use_event, reason)
      @session.log.append(
        type: :tool_result,
        payload: Events::ToolResult.new(
          tool_use_id: tool_use_event.payload[:id],
          error: "denied by hook: #{reason || "no reason given"}"
        ).to_h
      )
    end
  end
end
