# frozen_string_literal: true

require "harnas/actions/refuse"

RSpec.describe Harnas::Actions::Refuse do
  it "returns a deny decision hash" do
    expect(described_class.call).to eq({ allow: false, reason: nil })
  end

  it "carries the reason when provided" do
    expect(described_class.call(reason: "policy"))
      .to eq({ allow: false, reason: "policy" })
  end

  it "is compatible with AgentLoop's any-deny-wins composition" do
    decisions = [{ allow: true }, described_class.call(reason: "nope")]
    denied    = decisions.find { |d| d[:allow] == false }
    expect(denied[:reason]).to eq("nope")
  end
end
