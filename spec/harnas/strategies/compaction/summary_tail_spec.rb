# frozen_string_literal: true

require "harnas/strategies/compaction/summary_tail"
require "harnas/session"
require "harnas/events/user_message"
require "harnas/events/assistant_message"
require "harnas/projections/anthropic"
require "harnas/ingestors/anthropic"
require "harnas/benchmark/canned_provider"

RSpec.describe Harnas::Strategies::Compaction::SummaryTail do
  let(:session) { Harnas::Session.create }
  let(:projection) { Harnas::Projections::Anthropic.new(model: "test") }
  let(:ingestor)   { Harnas::Ingestors::Anthropic.new }
  let(:provider) do
    Harnas::Benchmark::CannedProvider.new(response_text: "[canned summary]")
  end

  def append_user(session, text)
    session.log.append(
      type: :user_message,
      payload: Harnas::Events::UserMessage.new(text: text).to_h
    )
  end

  def append_assistant(session, text)
    session.log.append(
      type: :assistant_message,
      payload: Harnas::Events::AssistantMessage.new(
        text: text, stop_reason: :end_turn, usage: {}
      ).to_h
    )
  end

  describe "construction" do
    it "rejects a non-callable projection" do
      expect do
        described_class.new(
          projection: :nope, provider: provider, ingestor: ingestor,
          max_messages: 5, keep_recent: 2
        )
      end.to raise_error(ArgumentError, /projection must respond to #call/)
    end

    it "rejects a non-callable provider" do
      expect do
        described_class.new(
          projection: projection, provider: :nope, ingestor: ingestor,
          max_messages: 5, keep_recent: 2
        )
      end.to raise_error(ArgumentError, /provider must respond to #call/)
    end

    it "rejects a non-callable ingestor" do
      expect do
        described_class.new(
          projection: projection, provider: provider, ingestor: :nope,
          max_messages: 5, keep_recent: 2
        )
      end.to raise_error(ArgumentError, /ingestor must respond to #call/)
    end

    it "rejects keep_recent >= max_messages" do
      expect do
        described_class.new(
          projection: projection, provider: provider, ingestor: ingestor,
          max_messages: 5, keep_recent: 5
        )
      end.to raise_error(ArgumentError, /max_messages must be > keep_recent/)
    end
  end

  describe "#on_pre_projection" do
    it "is a no-op when message count is at or below max_messages" do
      3.times { |i| append_user(session, "u#{i}") }

      Harnas::Hooks.scoped do
        described_class.install(
          projection: projection, provider: provider, ingestor: ingestor,
          max_messages: 5, keep_recent: 2
        )
        Harnas::Hooks.invoke(:pre_projection, session: session)
      end

      expect(session.log.map(&:type)).not_to include(:compact)
    end

    it "appends a :compact Event whose summary is the Provider's assistant text" do
      10.times { |i| append_user(session, "u#{i}") }

      Harnas::Hooks.scoped do
        described_class.install(
          projection: projection, provider: provider, ingestor: ingestor,
          max_messages: 5, keep_recent: 2
        )
        Harnas::Hooks.invoke(:pre_projection, session: session)
      end

      compact = session.log.find { |e| e.type == :compact }
      expect(compact.payload[:summary]).to eq("[canned summary]")
    end

    it "sends the events-to-compact plus the prompt to the Provider" do
      sent_request = nil
      spy_provider = Class.new do
        def initialize(captured) = @captured = captured

        def call(request)
          @captured.call(request)
          {
            "content" => [{ "type" => "text", "text" => "summary" }],
            "stop_reason" => "end_turn",
            "usage" => { "input_tokens" => 1, "output_tokens" => 1 }
          }
        end
      end.new(->(req) { sent_request = req })

      5.times { |i| append_user(session, "old#{i}") }

      Harnas::Hooks.scoped do
        described_class.install(
          projection: projection, provider: spy_provider, ingestor: ingestor,
          max_messages: 3, keep_recent: 1, prompt: "SUMMARIZE PLEASE"
        )
        Harnas::Hooks.invoke(:pre_projection, session: session)
      end

      # The sub-Log projection carries one user-role message whose content
      # contains the old messages followed by the prompt (messages of the
      # same role collapse into a single content array in the Anthropic
      # Projection).
      content = sent_request[:messages].first[:content]
      texts = content.is_a?(Array) ? content.map { |b| b[:text] } : [content]
      expect(texts.last).to eq("SUMMARIZE PLEASE")
      expect(texts).to include("old0", "old1", "old2", "old3")
      expect(texts).not_to include("old4") # last one is kept, not compacted
    end

    it "does not compact when the Provider returns no assistant text" do
      silent_provider = Class.new do
        def call(_request)
          {
            "content" => [],
            "stop_reason" => "end_turn",
            "usage" => { "input_tokens" => 1, "output_tokens" => 0 }
          }
        end
      end.new

      10.times { |i| append_user(session, "u#{i}") }

      Harnas::Hooks.scoped do
        described_class.install(
          projection: projection, provider: silent_provider, ingestor: ingestor,
          max_messages: 5, keep_recent: 2
        )
        Harnas::Hooks.invoke(:pre_projection, session: session)
      end

      expect(session.log.map(&:type)).not_to include(:compact)
    end

    it "is idempotent: a second pass on an already-compacted Log does not re-trigger" do
      5.times { |i| append_user(session, "u#{i}") }

      Harnas::Hooks.scoped do
        described_class.install(
          projection: projection, provider: provider, ingestor: ingestor,
          max_messages: 4, keep_recent: 2
        )
        Harnas::Hooks.invoke(:pre_projection, session: session)
        Harnas::Hooks.invoke(:pre_projection, session: session)
      end

      expect(session.log.select { |e| e.type == :compact }.size).to eq(1)
    end

    it "returns a handler that can be removed via Harnas::Hooks.off" do
      handler = described_class.install(
        projection: projection, provider: provider, ingestor: ingestor,
        max_messages: 5, keep_recent: 2
      )
      expect(Harnas::Hooks.handlers[:pre_projection]).to include(handler)

      Harnas::Hooks.off(:pre_projection, handler)
      expect(Harnas::Hooks.handlers[:pre_projection]).not_to include(handler)
    end
  end

  describe "integration with Projections" do
    it "causes the next Anthropic Projection of the session to emit the LLM-generated summary" do
      10.times { |i| append_user(session, "msg#{i}") }

      Harnas::Hooks.scoped do
        described_class.install(
          projection: projection, provider: provider, ingestor: ingestor,
          max_messages: 4, keep_recent: 2
        )
        Harnas::Hooks.invoke(:pre_projection, session: session)

        result = projection.call(session.log)
        expect(result[:messages].size).to eq(1)
        content_texts = result[:messages].first[:content].map { |b| b[:text] }
        expect(content_texts).to include("[canned summary]")
        expect(content_texts).to include("msg8", "msg9")
      end
    end
  end
end
