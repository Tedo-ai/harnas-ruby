# frozen_string_literal: true

require "harnas/events/tool_use"

RSpec.describe Harnas::Events::ToolUse do
  def make(**overrides)
    defaults = { id: "toolu_1", name: "echo", arguments: { text: "hi" } }
    described_class.new(**defaults, **overrides)
  end

  it "holds id, name, and arguments" do
    tu = make
    expect(tu.id).to eq("toolu_1")
    expect(tu.name).to eq("echo")
    expect(tu.arguments).to eq({ text: "hi" })
  end

  it "is frozen (immutable)" do
    expect(make).to be_frozen
  end

  it "rejects a non-String id" do
    expect { make(id: 123) }
      .to raise_error(ArgumentError, /id must be a String/)
  end

  it "rejects an empty id" do
    expect { make(id: "") }
      .to raise_error(ArgumentError, /id must not be empty/)
  end

  it "rejects a non-String name" do
    expect { make(name: nil) }
      .to raise_error(ArgumentError, /name must be a String/)
  end

  it "rejects an empty name" do
    expect { make(name: "") }
      .to raise_error(ArgumentError, /name must not be empty/)
  end

  it "rejects a non-Hash arguments" do
    expect { make(arguments: "hi") }
      .to raise_error(ArgumentError, /arguments must be a Hash/)
  end

  it "accepts empty arguments" do
    expect { make(arguments: {}) }.not_to raise_error
  end

  it "is equal to another ToolUse with the same fields" do
    expect(make).to eq(make)
  end

  it "serializes to a hash via #to_h" do
    expect(make.to_h).to eq({ id: "toolu_1", name: "echo", arguments: { text: "hi" } })
  end
end
