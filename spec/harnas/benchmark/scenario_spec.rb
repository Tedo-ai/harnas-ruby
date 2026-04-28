# frozen_string_literal: true

require "harnas/benchmark/scenario"

RSpec.describe Harnas::Benchmark::Scenario do
  it "holds name, description, and prompts" do
    s = described_class.new(
      name: "long-conversation",
      description: "A multi-turn conversation exercising context growth.",
      prompts: ["hi", "how are you?"]
    )
    expect(s.name).to eq("long-conversation")
    expect(s.prompts).to eq(["hi", "how are you?"])
    expect(s.canned_responses).to be_nil
  end

  it "is frozen (immutable)" do
    s = described_class.new(name: "x", description: "y", prompts: ["z"])
    expect(s).to be_frozen
  end

  it "rejects an empty prompts array" do
    expect { described_class.new(name: "x", description: "", prompts: []) }
      .to raise_error(ArgumentError, /prompts must be a non-empty Array/)
  end

  it "accepts canned_responses of matching length" do
    s = described_class.new(
      name: "x", description: "", prompts: %w[a b], canned_responses: %w[r1 r2]
    )
    expect(s.canned_responses).to eq(%w[r1 r2])
  end

  it "rejects canned_responses of mismatched length" do
    expect do
      described_class.new(
        name: "x", description: "", prompts: %w[a b], canned_responses: %w[r1]
      )
    end.to raise_error(ArgumentError, /one entry per prompt/)
  end
end
