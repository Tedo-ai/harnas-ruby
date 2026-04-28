# frozen_string_literal: true

require "harnas/agent"
require "harnas/manifest"
require "harnas/conformance/scripted_provider"
require "harnas/conformance/scripted_stream_provider"

RSpec.describe Harnas::Agent do
  let(:mock_manifest) do
    {
      "harnas_version" => "0.1",
      "name" => "test-agent",
      "provider" => {
        "kind" => "mock",
        "model" => "mock-test",
        "max_tokens" => 1024
      },
      "tools" => [],
      "strategies" => []
    }
  end

  def build_agent(texts, manifest: mock_manifest,
                  max_turns: Harnas::AgentLoop::DEFAULT_MAX_TURNS)
    agent = Harnas::Agent.from_manifest(manifest, max_turns: max_turns)
    agent.use_provider(
      Harnas::Conformance::ScriptedProvider.new(responses: scripted_responses(texts))
    )
  end

  def scripted_responses(texts)
    Array(texts).map do |text|
      {
        "content" => [{ "type" => "text", "text" => text }],
        "stop_reason" => "end_turn",
        "usage" => { "input_tokens" => 1, "output_tokens" => 1 }
      }
    end
  end

  describe ".from_manifest" do
    it "loads a Hash manifest and exposes session + registry + name" do
      agent = described_class.from_manifest(mock_manifest)
      expect(agent.name).to eq("test-agent")
      expect(agent.session).to be_a(Harnas::Session)
      expect(agent.registry).to be_a(Harnas::Tools::Registry)
    end
  end

  describe "#chat" do
    it "appends the user message, drives a turn, and returns the final Response" do
      Harnas::Hooks.scoped do
        agent = build_agent(["hello from agent"])
        response = agent.chat("hi")

        expect(response.text).to eq("hello from agent")
        expect(response.stop_reason).to eq(:end_turn)
        expect(response.log.map(&:type)).to eq(%i[user_message assistant_message])
      end
    end

    it "preserves the Log across multiple calls" do
      Harnas::Hooks.scoped do
        agent = build_agent(["first answer", "second answer"])
        agent.chat("question one")
        agent.chat("question two")

        types = agent.log.map(&:type)
        expect(types).to eq(
          %i[user_message assistant_message user_message assistant_message]
        )
        expect(agent.log.map { |e| e.payload[:text] }.compact).to eq(
          ["question one", "first answer", "question two", "second answer"]
        )
      end
    end

    it "installs manifest-declared strategies on the first chat and keeps them" do
      manifest_with_strategy = mock_manifest.merge(
        "strategies" => [
          {
            "name" => "Compaction::MarkerTail",
            "config" => { "max_messages" => 10, "keep_recent" => 3 }
          }
        ]
      )

      agent = build_agent(%w[a b], manifest: manifest_with_strategy)
      before = agent.session.hooks.handlers[:pre_projection].size

      agent.chat("hi")
      after_first = agent.session.hooks.handlers[:pre_projection].size
      expect(after_first - before).to eq(1)

      agent.chat("hi again")
      expect(agent.session.hooks.handlers[:pre_projection].size).to eq(after_first)
      expect(Harnas::Hooks.handlers[:pre_projection]).to be_empty
    end
  end

  describe "#stream" do
    it "yields text delta Events as they are appended" do
      agent = described_class.from_manifest(mock_manifest)
      agent.use_stream_provider(
        Harnas::Conformance::ScriptedStreamProvider.new(
          streams: [
            [
              { "type" => "assistant_turn_started",
                "payload" => { "turn_id" => "turn_1" } },
              { "type" => "assistant_text_delta",
                "payload" => { "turn_id" => "turn_1", "chunk" => "he" } },
              { "type" => "assistant_text_delta",
                "payload" => { "turn_id" => "turn_1", "chunk" => "llo" } },
              { "type" => "assistant_turn_completed",
                "payload" => { "turn_id" => "turn_1", "stop_reason" => "end_turn",
                               "usage" => { "input_tokens" => 1, "output_tokens" => 1 } } },
              { "type" => "assistant_message",
                "payload" => { "text" => "hello", "stop_reason" => "end_turn",
                               "usage" => { "input_tokens" => 1, "output_tokens" => 1 } } }
            ]
          ]
        )
      )

      yielded = []
      response = agent.stream("hi") { |event| yielded << event }

      expect(yielded.map(&:type)).to eq(%i[assistant_text_delta assistant_text_delta])
      expect(yielded.map { |event| event.payload[:chunk] }.join).to eq("hello")
      expect(response.text).to eq("hello")
    end

    it "falls back to buffered chat when no stream provider is configured" do
      agent = build_agent(["buffered"])
      yielded = []
      response = agent.stream("hi") { |event| yielded << event }

      expect(yielded).to be_empty
      expect(response.text).to eq("buffered")
    end
  end

  describe "#from_session" do
    it "continues execution from a supplied Session" do
      agent = build_agent(%w[first second])
      agent.chat("one")
      forked = agent.session.fork(at_seq: 0)
      forked_agent = agent.from_session(forked)

      response = forked_agent.chat("retry")

      expect(response.text).to eq("second")
      expect(forked_agent.session).to be(forked)
      expect(forked_agent.log.map { |event| event.payload[:text] }.compact)
        .to eq(%w[one retry second])
    end
  end

  describe "system prompt" do
    it "accepts a runtime override via the system: kwarg" do
      agent = described_class.from_manifest(mock_manifest, system: "You are Vera.")
      request = agent.instance_variable_get(:@loaded).projection.call(Harnas::Log.new)
      expect(request[:system]).to eq("You are Vera.")
    end

    it "uses the manifest's system field when no override is given" do
      manifest_with_system = mock_manifest.merge("system" => "You are Otto.")
      agent = described_class.from_manifest(manifest_with_system)
      request = agent.instance_variable_get(:@loaded).projection.call(Harnas::Log.new)
      expect(request[:system]).to eq("You are Otto.")
    end

    it "prefers the runtime override over the manifest's system field" do
      manifest_with_system = mock_manifest.merge("system" => "from manifest")
      agent = described_class.from_manifest(manifest_with_system, system: "from runtime")
      request = agent.instance_variable_get(:@loaded).projection.call(Harnas::Log.new)
      expect(request[:system]).to eq("from runtime")
    end
  end

  describe "#shutdown" do
    it "removes every strategy handler the agent installed" do
      manifest_with_strategy = mock_manifest.merge(
        "strategies" => [
          {
            "name" => "Compaction::MarkerTail",
            "config" => { "max_messages" => 10, "keep_recent" => 3 }
          }
        ]
      )

      Harnas::Hooks.scoped do
        before = Harnas::Hooks.handlers[:pre_projection].size
        agent = build_agent(["ok"], manifest: manifest_with_strategy)
        agent.chat("hi")
        agent.shutdown

        expect(Harnas::Hooks.handlers[:pre_projection].size).to eq(before)
      end
    end

    it "is idempotent" do
      Harnas::Hooks.scoped do
        agent = build_agent(["ok"])
        expect { 2.times { agent.shutdown } }.not_to raise_error
      end
    end
  end
end
