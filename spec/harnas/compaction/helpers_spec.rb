# frozen_string_literal: true

require "harnas/compaction/helpers"
require "harnas/log"
require "harnas/events/user_message"
require "harnas/events/assistant_message"
require "harnas/events/tool_use"
require "harnas/events/tool_result"

RSpec.describe Harnas::Compaction::Helpers do
  let(:log) { Harnas::Log.new }

  def append_user(log, text)
    log.append(
      type: :user_message,
      payload: Harnas::Events::UserMessage.new(text: text).to_h
    )
  end

  def append_assistant(log, text)
    log.append(
      type: :assistant_message,
      payload: Harnas::Events::AssistantMessage.new(
        text: text, stop_reason: :end_turn, usage: {}
      ).to_h
    )
  end

  def append_tool_use(log, id:, name: "echo", arguments: { text: "hi" })
    log.append(
      type: :tool_use,
      payload: Harnas::Events::ToolUse.new(id: id, name: name, arguments: arguments).to_h
    )
  end

  def append_tool_result(log, tool_use_id:, output: "ok")
    log.append(
      type: :tool_result,
      payload: Harnas::Events::ToolResult.new(tool_use_id: tool_use_id, output: output).to_h
    )
  end

  describe ".message_events" do
    it "returns the 4 real message types from the Log" do
      append_user(log, "hi")
      append_assistant(log, "hello")
      append_tool_use(log, id: "t1")
      append_tool_result(log, tool_use_id: "t1")

      events = described_class.message_events(log)
      expect(events.size).to eq(4)
      expect(events.map(&:type)).to eq(%i[user_message assistant_message tool_use tool_result])
    end

    it "excludes :summary events (idempotency guarantee)" do
      append_user(log, "a")
      append_user(log, "b")
      log.append(
        type: :compact,
        payload: Harnas::Events::Compact.new(replaces: [0], summary: "S").to_h
      )

      # After Mutations.apply: [:summary, :user_message] but .message_events
      # filters out :summary, leaving only :user_message.
      events = described_class.message_events(log)
      expect(events.map(&:type)).to eq(%i[user_message])
    end
  end

  describe ".estimate_tokens" do
    it "returns a non-negative Integer" do
      append_user(log, "hello world")
      events = described_class.message_events(log)
      expect(described_class.estimate_tokens(events)).to be_a(Integer)
      expect(described_class.estimate_tokens(events)).to be >= 0
    end

    it "scales roughly with text length (4 chars per token heuristic)" do
      append_user(log, "x" * 400) # 400 chars → ~100 tokens
      events = described_class.message_events(log)
      expect(described_class.estimate_tokens(events)).to be_within(5).of(100)
    end

    it "returns 0 for an empty event list" do
      expect(described_class.estimate_tokens([])).to eq(0)
    end
  end

  describe ".tool_pair_safe_range" do
    it "leaves candidates untouched when they don't touch any tool pair" do
      append_user(log, "a")          # seq 0
      append_user(log, "b")          # seq 1
      append_assistant(log, "c")     # seq 2

      expect(described_class.tool_pair_safe_range(log, [0, 1])).to eq([0, 1])
    end

    it "keeps an intact tool pair when both halves are in the candidates" do
      append_user(log, "q")                           # seq 0
      append_tool_use(log, id: "t1")                  # seq 1
      append_tool_result(log, tool_use_id: "t1")      # seq 2

      expect(described_class.tool_pair_safe_range(log, [0, 1, 2])).to eq([0, 1, 2])
    end

    it "drops a :tool_use from candidates when its :tool_result is not in candidates" do
      append_user(log, "q")                           # seq 0
      append_tool_use(log, id: "t1")                  # seq 1
      append_tool_result(log, tool_use_id: "t1")      # seq 2

      # Candidate set: [0, 1] — use in, result out. Must drop the use.
      expect(described_class.tool_pair_safe_range(log, [0, 1])).to eq([0])
    end

    it "drops a :tool_result from candidates when its :tool_use is not in candidates" do
      append_tool_use(log, id: "t1")                  # seq 0
      append_tool_result(log, tool_use_id: "t1")      # seq 1
      append_user(log, "later")                       # seq 2

      # Candidate set: [1, 2] — result in, use out. Must drop the result.
      expect(described_class.tool_pair_safe_range(log, [1, 2])).to eq([2])
    end

    it "handles multiple tool pairs independently" do
      append_user(log, "q")                           # seq 0
      append_tool_use(log, id: "t1")                  # seq 1
      append_tool_result(log, tool_use_id: "t1")      # seq 2
      append_tool_use(log, id: "t2")                  # seq 3
      append_tool_result(log, tool_use_id: "t2")      # seq 4

      # Candidates include pair1 complete + pair2's use only → drop use only.
      expect(described_class.tool_pair_safe_range(log, [0, 1, 2, 3])).to eq([0, 1, 2])
    end

    it "ignores an in-flight :tool_use that has no matching :tool_result yet" do
      append_user(log, "q")                           # seq 0
      append_tool_use(log, id: "t1")                  # seq 1 (no result yet)

      # Candidate includes the orphan :tool_use; with no matching result
      # in the Log, there's no pair to enforce → pass through unchanged.
      expect(described_class.tool_pair_safe_range(log, [0, 1])).to eq([0, 1])
    end

    it "returns an empty Array when given one" do
      append_user(log, "a")
      expect(described_class.tool_pair_safe_range(log, [])).to eq([])
    end
  end
end
