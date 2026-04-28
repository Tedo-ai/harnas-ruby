# frozen_string_literal: true

require "harnas/events/compact"

RSpec.describe Harnas::Events::Compact do
  def make(**overrides)
    defaults = { replaces: [0, 1, 2], summary: "Discussed onboarding flow." }
    described_class.new(**defaults, **overrides)
  end

  it "holds replaces and summary" do
    c = make
    expect(c.replaces).to eq([0, 1, 2])
    expect(c.summary).to eq("Discussed onboarding flow.")
  end

  it "is frozen (immutable)" do
    expect(make).to be_frozen
  end

  it "rejects a non-Array replaces" do
    expect { make(replaces: "0,1,2") }
      .to raise_error(ArgumentError, /replaces must be an Array/)
  end

  it "rejects an empty replaces" do
    expect { make(replaces: []) }
      .to raise_error(ArgumentError, /replaces must not be empty/)
  end

  it "rejects an Array containing non-Integers" do
    expect { make(replaces: [0, "1", 2]) }
      .to raise_error(ArgumentError, /replaces must be an Array of non-negative Integers/)
  end

  it "rejects an Array containing negative Integers" do
    expect { make(replaces: [0, -1]) }
      .to raise_error(ArgumentError, /replaces must be an Array of non-negative Integers/)
  end

  it "rejects a non-String summary" do
    expect { make(summary: nil) }
      .to raise_error(ArgumentError, /summary must be a String/)
  end

  it "rejects an empty summary" do
    expect { make(summary: "") }
      .to raise_error(ArgumentError, /summary must not be empty/)
  end

  it "is equal to another Compact with the same fields" do
    expect(make).to eq(make)
  end

  it "serializes to a hash via #to_h" do
    expect(make.to_h).to eq({ replaces: [0, 1, 2], summary: "Discussed onboarding flow." })
  end
end
