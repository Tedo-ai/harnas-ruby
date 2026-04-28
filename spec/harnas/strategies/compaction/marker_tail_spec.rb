# frozen_string_literal: true

require "harnas/strategies/compaction/marker_tail"
require "harnas/session"
require "harnas/events/user_message"
require "harnas/events/assistant_message"

RSpec.describe Harnas::Strategies::Compaction::MarkerTail do
  let(:session) { Harnas::Session.create }

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
    it "rejects keep_recent >= max_messages" do
      expect { described_class.new(max_messages: 5, keep_recent: 5) }
        .to raise_error(ArgumentError, /max_messages must be > keep_recent/)
    end

    it "rejects a negative keep_recent" do
      expect { described_class.new(max_messages: 10, keep_recent: -1) }
        .to raise_error(ArgumentError, /max_messages must be > keep_recent/)
    end
  end

  describe "#on_pre_projection" do
    it "is a no-op when message count is at or below max_messages" do
      3.times { |i| append_user(session, "u#{i}") }

      Harnas::Hooks.scoped do
        described_class.install(max_messages: 5, keep_recent: 2)
        Harnas::Hooks.invoke(:pre_projection, session: session)
      end

      expect(session.log.map(&:type)).not_to include(:compact)
    end

    it "appends a :compact Event when message count exceeds max_messages" do
      10.times { |i| append_user(session, "u#{i}") }

      Harnas::Hooks.scoped do
        described_class.install(max_messages: 5, keep_recent: 2)
        Harnas::Hooks.invoke(:pre_projection, session: session)
      end

      compacts = session.log.select { |e| e.type == :compact }
      expect(compacts.size).to eq(1)
    end

    it "compacts exactly the oldest (count - keep_recent) messages" do
      10.times { |i| append_user(session, "u#{i}") }

      Harnas::Hooks.scoped do
        described_class.install(max_messages: 5, keep_recent: 3)
        Harnas::Hooks.invoke(:pre_projection, session: session)
      end

      compact = session.log.find { |e| e.type == :compact }
      # 10 messages, keep 3 → compact the first 7 (seqs 0..6)
      expect(compact.payload[:replaces]).to eq([0, 1, 2, 3, 4, 5, 6])
    end

    it "compacts across user/assistant/tool_use/tool_result alike" do
      append_user(session, "u1")           # seq 0
      append_assistant(session, "a1")      # seq 1
      append_user(session, "u2")           # seq 2
      append_assistant(session, "a2")      # seq 3
      append_user(session, "u3")           # seq 4

      Harnas::Hooks.scoped do
        described_class.install(max_messages: 3, keep_recent: 1)
        Harnas::Hooks.invoke(:pre_projection, session: session)
      end

      compact = session.log.find { |e| e.type == :compact }
      expect(compact.payload[:replaces]).to eq([0, 1, 2, 3])
    end

    it "does not count :summary events from prior compactions toward the threshold" do
      # Seed the Log with a :compact already applied (summary is visible).
      5.times { |i| append_user(session, "u#{i}") }

      # First pass: compact oldest 3, keep 2
      Harnas::Hooks.scoped do
        described_class.install(max_messages: 4, keep_recent: 2)
        Harnas::Hooks.invoke(:pre_projection, session: session)
      end

      # Now the projected view has: [summary, u3, u4] (3 effective events,
      # but only 2 are MESSAGE_TYPES — u3, u4). A second pass must NOT
      # compact again because 2 < 4.
      Harnas::Hooks.scoped do
        described_class.install(max_messages: 4, keep_recent: 2)
        Harnas::Hooks.invoke(:pre_projection, session: session)
      end

      # Only one :compact event in the Log
      expect(session.log.select { |e| e.type == :compact }.size).to eq(1)
    end

    it "returns a handler that can be removed via Harnas::Hooks.off" do
      handler = described_class.install(max_messages: 5, keep_recent: 2)
      expect(Harnas::Hooks.handlers[:pre_projection]).to include(handler)

      Harnas::Hooks.off(:pre_projection, handler)
      expect(Harnas::Hooks.handlers[:pre_projection]).not_to include(handler)
    end

    it "honors a caller-supplied summary_format with $N substitution" do
      10.times { |i| append_user(session, "u#{i}") }

      Harnas::Hooks.scoped do
        described_class.install(
          max_messages: 5, keep_recent: 2,
          summary_format: "compacted: $N"
        )
        Harnas::Hooks.invoke(:pre_projection, session: session)
      end

      compact = session.log.find { |e| e.type == :compact }
      expect(compact.payload[:summary]).to eq("compacted: 8")
    end

    it "emits the normative default summary format when no override is given" do
      10.times { |i| append_user(session, "u#{i}") }

      Harnas::Hooks.scoped do
        described_class.install(max_messages: 5, keep_recent: 2)
        Harnas::Hooks.invoke(:pre_projection, session: session)
      end

      compact = session.log.find { |e| e.type == :compact }
      expect(compact.payload[:summary]).to eq("[snipped 8 earlier messages]")
    end
  end

  describe "integration with Projections" do
    it "causes the Anthropic Projection to emit a compacted view on next call" do
      require "harnas/projections/anthropic"

      10.times { |i| append_user(session, "message#{i}") }

      Harnas::Hooks.scoped do
        described_class.install(max_messages: 4, keep_recent: 2)
        Harnas::Hooks.invoke(:pre_projection, session: session)

        projection = Harnas::Projections::Anthropic.new(model: "x")
        result     = projection.call(session.log)

        # Expect one user-role message with a content array containing
        # [summary text + 2 retained user messages].
        expect(result[:messages].size).to eq(1)
        content_texts = result[:messages].first[:content].map { |b| b[:text] }
        expect(content_texts).to include("[snipped 8 earlier messages]")
        expect(content_texts).to include("message8", "message9")
      end
    end
  end
end
