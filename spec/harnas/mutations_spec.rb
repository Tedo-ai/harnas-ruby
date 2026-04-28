# frozen_string_literal: true

require "harnas/mutations"
require "harnas/log"
require "harnas/events/user_message"
require "harnas/events/assistant_message"
require "harnas/events/compact"
require "harnas/events/revert"

RSpec.describe Harnas::Mutations do
  let(:log) { Harnas::Log.new }

  def append_user(log, text)
    log.append(type: :user_message, payload: Harnas::Events::UserMessage.new(text: text).to_h)
  end

  def append_assistant(log, text)
    log.append(
      type: :assistant_message,
      payload: Harnas::Events::AssistantMessage.new(text: text, stop_reason: :end_turn).to_h
    )
  end

  def append_compact(log, replaces:, summary:)
    log.append(
      type: :compact,
      payload: Harnas::Events::Compact.new(replaces: replaces, summary: summary).to_h
    )
  end

  def append_revert(log, revokes:)
    log.append(
      type: :revert,
      payload: Harnas::Events::Revert.new(revokes: revokes).to_h
    )
  end

  describe "with no mutations" do
    it "returns an empty Array for an empty Log" do
      expect(described_class.apply(log)).to eq([])
    end

    it "returns the original events unchanged" do
      a = append_user(log, "hi")
      b = append_assistant(log, "hello")
      expect(described_class.apply(log)).to eq([a, b])
    end
  end

  describe "with a single :compact mutation" do
    it "filters out the mutation event itself" do
      append_user(log, "hi")
      append_compact(log, replaces: [0], summary: "S")

      result = described_class.apply(log)
      expect(result.map(&:type)).not_to include(:compact)
    end

    it "replaces shadowed events with a synthesized :summary at the min replaced seq" do
      append_user(log, "first")
      append_assistant(log, "second")
      append_user(log, "third")
      append_compact(log, replaces: [0, 1], summary: "Discussed X")
      append_assistant(log, "fourth")

      result = described_class.apply(log)
      expect(result.map(&:type)).to eq(%i[summary user_message assistant_message])
      expect(result[0].payload).to eq({ text: "Discussed X" })
      expect(result[0].seq).to eq(3) # the compact's own seq
    end

    it "carries the compact's seq and id on the synthesized :summary" do
      a       = append_user(log, "hi")
      compact = append_compact(log, replaces: [a.seq], summary: "S")

      result = described_class.apply(log)
      expect(result.first.seq).to eq(compact.seq)
      expect(result.first.id).to  eq(compact.id)
    end
  end

  describe "with :revert" do
    it "undoes a :compact when revoked" do
      a = append_user(log, "kept")
      b = append_assistant(log, "also kept")
      compact = append_compact(log, replaces: [0, 1], summary: "S")
      append_revert(log, revokes: compact.seq)

      expect(described_class.apply(log)).to eq([a, b])
    end

    it "filters out the :revert event itself" do
      compact = append_compact(log, replaces: [0], summary: "S")
      append_revert(log, revokes: compact.seq)

      expect(described_class.apply(log).map(&:type)).not_to include(:revert)
    end
  end

  describe "with multiple non-overlapping :compact events" do
    it "applies both" do
      append_user(log, "a") # seq 0
      append_user(log, "b") # seq 1
      append_user(log, "c") # seq 2
      append_user(log, "d") # seq 3

      append_compact(log, replaces: [0, 1], summary: "First half")  # seq 4
      append_compact(log, replaces: [2, 3], summary: "Second half") # seq 5

      result = described_class.apply(log)
      expect(result.map(&:type)).to eq(%i[summary summary])
      expect(result.map { |e| e.payload[:text] }).to eq(["First half", "Second half"])
    end
  end
end
