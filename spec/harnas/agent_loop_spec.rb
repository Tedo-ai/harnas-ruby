# frozen_string_literal: true

require "harnas/agent_loop"
require "harnas/session"
require "harnas/events/user_message"
require "harnas/events/assistant_message"
require "harnas/events/tool_use"
require "harnas/events/tool_result"
require "harnas/log"
require "harnas/tools/tool"
require "harnas/tools/registry"
require "harnas/tools/runner"

# Scripted doubles used across the AgentLoop specs below.
class ScriptedProvider
  def initialize(responses)
    @responses = responses.dup
  end

  def call(_request)
    @responses.shift or raise "ScriptedProvider: out of responses"
  end
end

class ScriptedIngestor
  def initialize(queue)
    @queue = queue.dup
  end

  def call(_response)
    @queue.shift or raise "ScriptedIngestor: out of ingest results"
  end
end

# A provider that raises N times before succeeding once. Used by the
# AgentLoop retry/abort tests below.
class FlakyProvider
  def initialize(error:, fail_times:, then_response:)
    @error = error
    @fail_times = fail_times
    @then_response = then_response
    @calls = 0
  end

  def call(_request)
    @calls += 1
    raise @error if @calls <= @fail_times

    @then_response
  end
end

RSpec.describe Harnas::AgentLoop do
  before { Harnas::Hooks.reset! }
  after  { Harnas::Hooks.reset! }

  let(:session) { Harnas::Session.create }

  # A scripted projection that records invocations and returns the same
  # request every time (the AgentLoop does not inspect the request
  # itself — the provider returns what we tell it to).
  let(:projection) { ->(_log) { { model: "x", messages: [] } } }

  describe "with a simple two-turn tool round-trip script" do
    let(:registry) do
      r = Harnas::Tools::Registry.new
      r.register(
        Harnas::Tools::Tool.new(
          name: "echo", description: "", input_schema: {}
        ) { |args| args[:text].to_s }
      )
      r
    end
    let(:runner) { Harnas::Tools::Runner.new(registry) }

    let(:turn1_events) do
      [
        { type: :assistant_message,
          payload: Harnas::Events::AssistantMessage.new(
            text: "I'll use echo", stop_reason: :tool_use, usage: {}
          ).to_h },
        { type: :tool_use,
          payload: Harnas::Events::ToolUse.new(
            id: "toolu_1", name: "echo", arguments: { text: "hi" }
          ).to_h }
      ]
    end

    let(:turn2_events) do
      [
        { type: :assistant_message,
          payload: Harnas::Events::AssistantMessage.new(
            text: "done", stop_reason: :end_turn, usage: {}
          ).to_h }
      ]
    end

    before do
      session.log.append(
        type: :user_message,
        payload: Harnas::Events::UserMessage.new(text: "use echo").to_h
      )
    end

    subject(:loop_runner) do
      described_class.new(
        session: session,
        projection: projection,
        provider: ScriptedProvider.new(%i[resp1 resp2]),
        ingestor: ScriptedIngestor.new([turn1_events, turn2_events]),
        runner: runner
      )
    end

    it "runs until stop_reason is :end_turn and returns :end_turn" do
      expect(loop_runner.run).to eq(:end_turn)
    end

    it "produces the canonical 5-event Log (user, assistant, tool_use, tool_result, assistant)" do
      loop_runner.run
      expect(session.log.map(&:type)).to eq(%i[
                                              user_message
                                              assistant_message
                                              tool_use
                                              tool_result
                                              assistant_message
                                            ])
    end

    it "executes the registered tool and records its output in the :tool_result payload" do
      loop_runner.run
      tool_result = session.log.find { |e| e.type == :tool_result }
      expect(tool_result.payload[:output]).to eq("hi")
      expect(tool_result.payload[:error]).to be_nil
    end
  end

  describe "hook invocation points" do
    let(:registry) do
      r = Harnas::Tools::Registry.new
      r.register(
        Harnas::Tools::Tool.new(
          name: "echo", description: "", input_schema: {}
        ) { |args| args[:text].to_s }
      )
      r
    end

    let(:end_turn_events) do
      [
        { type: :assistant_message,
          payload: Harnas::Events::AssistantMessage.new(
            text: "hi", stop_reason: :end_turn, usage: {}
          ).to_h }
      ]
    end

    subject(:loop_runner) do
      described_class.new(
        session: session,
        projection: projection,
        provider: ScriptedProvider.new([:resp]),
        ingestor: ScriptedIngestor.new([end_turn_events]),
        runner: Harnas::Tools::Runner.new(registry)
      )
    end

    before do
      session.log.append(type: :user_message,
                         payload: Harnas::Events::UserMessage.new(text: "hi").to_h)
    end

    it "fires session_started / turn_started / turn_ended / session_ended in order" do
      fired = []
      %i[session_started turn_started turn_ended session_ended].each do |point|
        session.hooks.on(point) { |**_| fired << point }
      end
      loop_runner.run
      expect(fired).to eq(%i[session_started turn_started turn_ended session_ended])
    end

    it "fires the request-path hooks (pre/post projection, pre/post provider_call)" do
      fired = []
      %i[pre_projection post_projection pre_provider_call post_provider_call].each do |point|
        session.hooks.on(point) { |**_| fired << point }
      end
      loop_runner.run
      expect(fired).to eq(%i[pre_projection post_projection pre_provider_call post_provider_call])
    end

    it "fires pre_ingest / post_ingest bracketing the Ingestor call" do
      fired = []
      %i[pre_ingest post_ingest].each do |point|
        session.hooks.on(point) { |**_| fired << point }
      end
      loop_runner.run
      expect(fired).to eq(%i[pre_ingest post_ingest])
    end

    it "passes the stop_reason in the turn_ended payload" do
      captured = nil
      session.hooks.on(:turn_ended) { |stop_reason:, **_| captured = stop_reason }
      loop_runner.run
      expect(captured).to eq(:end_turn)
    end

    it "passes the exit reason in the session_ended payload" do
      captured = nil
      session.hooks.on(:session_ended) { |reason:, **_| captured = reason }
      loop_runner.run
      expect(captured).to eq(:end_turn)
    end

    it "scopes hooks to the Session running the loop" do
      other_session = Harnas::Session.create
      fired = []
      session.hooks.on(:pre_projection) { |**_| fired << :current }
      other_session.hooks.on(:pre_projection) { |**_| fired << :other }

      loop_runner.run

      expect(fired).to eq([:current])
    end
  end

  describe ":pre_tool_use permission hook" do
    let(:registry) do
      r = Harnas::Tools::Registry.new
      r.register(
        Harnas::Tools::Tool.new(
          name: "echo", description: "", input_schema: {}
        ) { |args| args[:text].to_s }
      )
      r
    end

    let(:turn1_events) do
      [
        { type: :assistant_message,
          payload: Harnas::Events::AssistantMessage.new(
            text: "", stop_reason: :tool_use, usage: {}
          ).to_h },
        { type: :tool_use,
          payload: Harnas::Events::ToolUse.new(
            id: "toolu_1", name: "echo", arguments: { text: "hi" }
          ).to_h }
      ]
    end

    let(:turn2_events) do
      [
        { type: :assistant_message,
          payload: Harnas::Events::AssistantMessage.new(
            text: "ok", stop_reason: :end_turn, usage: {}
          ).to_h }
      ]
    end

    subject(:loop_runner) do
      described_class.new(
        session: session,
        projection: projection,
        provider: ScriptedProvider.new(%i[r1 r2]),
        ingestor: ScriptedIngestor.new([turn1_events, turn2_events]),
        runner: Harnas::Tools::Runner.new(registry)
      )
    end

    before do
      session.log.append(type: :user_message,
                         payload: Harnas::Events::UserMessage.new(text: "go").to_h)
    end

    it "denies the tool and appends a failure tool_result when a handler returns allow: false" do
      session.hooks.on(:pre_tool_use) { |**_| { allow: false, reason: "testing" } }
      loop_runner.run

      tool_result = session.log.find { |e| e.type == :tool_result }
      expect(tool_result.payload[:error]).to match(/denied by hook: testing/)
      expect(tool_result.payload[:output]).to be_nil
    end

    it "allows the tool when no pre_tool_use handler is registered (default allow)" do
      loop_runner.run

      tool_result = session.log.find { |e| e.type == :tool_result }
      expect(tool_result.payload[:output]).to eq("hi")
    end

    it "allows the tool when all handlers return allow: true" do
      session.hooks.on(:pre_tool_use) { |**_| { allow: true } }
      loop_runner.run

      tool_result = session.log.find { |e| e.type == :tool_result }
      expect(tool_result.payload[:output]).to eq("hi")
    end

    it "denies when any handler denies (any-deny-wins)" do
      session.hooks.on(:pre_tool_use) { |**_| { allow: true } }
      session.hooks.on(:pre_tool_use) { |**_| { allow: false, reason: "second" } }
      session.hooks.on(:pre_tool_use) { |**_| { allow: true } }
      loop_runner.run

      tool_result = session.log.find { |e| e.type == :tool_result }
      expect(tool_result.payload[:error]).to match(/denied by hook: second/)
    end
  end

  describe "termination" do
    it "returns :max_turns_reached when the loop never hits end_turn" do
      # A script that always returns :tool_use with a new tool_use — registry
      # unknown so it'll record errors but keep looping.
      endless_events = lambda do
        [
          { type: :assistant_message,
            payload: Harnas::Events::AssistantMessage.new(
              text: "", stop_reason: :tool_use, usage: {}
            ).to_h },
          { type: :tool_use,
            payload: Harnas::Events::ToolUse.new(
              id: "t_#{rand(10_000)}", name: "unknown", arguments: {}
            ).to_h }
        ]
      end
      session.log.append(type: :user_message,
                         payload: Harnas::Events::UserMessage.new(text: "go").to_h)

      loop_runner = described_class.new(
        session: session,
        projection: projection,
        provider: ScriptedProvider.new([:r] * 3),
        ingestor: ScriptedIngestor.new(Array.new(3) { endless_events.call }),
        runner: Harnas::Tools::Runner.new(Harnas::Tools::Registry.new),
        max_turns: 3
      )

      expect(loop_runner.run).to eq(:max_turns_reached)
    end
  end

  describe "provider error handling" do
    let(:noop_backoff) { ->(_attempt) { 0 } }

    let(:end_turn_events) do
      [
        { type: :assistant_message,
          payload: Harnas::Events::AssistantMessage.new(
            text: "ok", stop_reason: :end_turn, usage: {}
          ).to_h }
      ]
    end

    before do
      session.log.append(type: :user_message,
                         payload: Harnas::Events::UserMessage.new(text: "go").to_h)
    end

    it "retries a transient HTTP 503 and continues to :end_turn on success" do
      provider = FlakyProvider.new(
        error: Harnas::Providers::HTTPError.new(503, "Service Unavailable"),
        fail_times: 2,
        then_response: :ok
      )
      ingestor = ScriptedIngestor.new([end_turn_events])
      runner   = described_class.new(
        session: session, projection: projection,
        provider: provider, ingestor: ingestor,
        retry_policy: Harnas::Providers::RetryPolicy.new(backoff_ms: noop_backoff)
      )

      expect(runner.run).to eq(:end_turn)

      errors = session.log.select { |e| e.type == :provider_error }
      expect(errors.size).to eq(2)
      expect(errors.map { |e| e.payload[:terminal] }).to eq([false, false])
      expect(errors.map { |e| e.payload[:status] }).to eq([503, 503])
      expect(errors.map { |e| e.payload[:attempt] }).to eq([1, 2])
    end

    it "appends a terminal :provider_error and ends with :provider_failed when retries exhaust" do
      provider = FlakyProvider.new(
        error: Harnas::Providers::HTTPError.new(503, "Service Unavailable"),
        fail_times: 5,
        then_response: :unused
      )
      runner = described_class.new(
        session: session, projection: projection,
        provider: provider, ingestor: ScriptedIngestor.new([end_turn_events]),
        retry_policy: Harnas::Providers::RetryPolicy.new(
          max_attempts: 3, backoff_ms: noop_backoff
        )
      )

      expect(runner.run).to eq(:provider_failed)

      errors = session.log.select { |e| e.type == :provider_error }
      expect(errors.size).to eq(3)
      expect(errors.last.payload[:terminal]).to be(true)
    end

    it "aborts immediately on a non-retryable HTTP 400" do
      provider = FlakyProvider.new(
        error: Harnas::Providers::HTTPError.new(400, "bad request"),
        fail_times: 1,
        then_response: :unused
      )
      runner = described_class.new(
        session: session, projection: projection,
        provider: provider, ingestor: ScriptedIngestor.new([end_turn_events]),
        retry_policy: Harnas::Providers::RetryPolicy.new(backoff_ms: noop_backoff)
      )

      expect(runner.run).to eq(:provider_failed)

      errors = session.log.select { |e| e.type == :provider_error }
      expect(errors.size).to eq(1)
      expect(errors.first.payload[:terminal]).to be(true)
      expect(errors.first.payload[:status]).to eq(400)
    end

    it "uses the provider's explicit kind for provider_error events" do
      stub_provider = Class.new do
        attr_reader :kind

        def initialize
          @kind = :openai
        end

        define_method(:call) do |_req|
          raise Harnas::Providers::HTTPError.new(400, "x")
        end
      end

      provider = stub_provider.new
      runner = described_class.new(
        session: session, projection: projection,
        provider: provider, ingestor: ScriptedIngestor.new([end_turn_events]),
        retry_policy: Harnas::Providers::RetryPolicy.new(backoff_ms: noop_backoff)
      )
      runner.run

      err = session.log.find { |e| e.type == :provider_error }
      expect(err.payload[:provider]).to eq(:openai)
    end
  end
end
