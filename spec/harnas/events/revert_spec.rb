# frozen_string_literal: true

require "harnas/events/revert"

RSpec.describe Harnas::Events::Revert do
  it "holds revokes" do
    expect(described_class.new(revokes: 5).revokes).to eq(5)
  end

  it "is frozen (immutable)" do
    expect(described_class.new(revokes: 0)).to be_frozen
  end

  it "rejects a non-Integer revokes" do
    expect { described_class.new(revokes: "5") }
      .to raise_error(ArgumentError, /revokes must be a non-negative Integer/)
  end

  it "rejects a negative revokes" do
    expect { described_class.new(revokes: -1) }
      .to raise_error(ArgumentError, /revokes must be a non-negative Integer/)
  end

  it "is equal to another Revert with the same seq" do
    expect(described_class.new(revokes: 3)).to eq(described_class.new(revokes: 3))
  end

  it "serializes to a hash via #to_h" do
    expect(described_class.new(revokes: 7).to_h).to eq({ revokes: 7 })
  end
end
