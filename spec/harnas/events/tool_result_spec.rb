# frozen_string_literal: true

require "harnas/events/tool_result"

RSpec.describe Harnas::Events::ToolResult do
  describe "successful result" do
    it "holds tool_use_id and output; error is nil" do
      r = described_class.new(tool_use_id: "toolu_1", output: "42")
      expect(r.tool_use_id).to eq("toolu_1")
      expect(r.output).to eq("42")
      expect(r.error).to be_nil
    end
  end

  describe "failed result" do
    it "holds tool_use_id and error; output is nil" do
      r = described_class.new(tool_use_id: "toolu_1", error: "boom")
      expect(r.tool_use_id).to eq("toolu_1")
      expect(r.error).to eq("boom")
      expect(r.output).to be_nil
    end
  end

  it "is frozen (immutable)" do
    expect(described_class.new(tool_use_id: "toolu_1", output: "x")).to be_frozen
  end

  it "rejects a non-String tool_use_id" do
    expect { described_class.new(tool_use_id: 1, output: "x") }
      .to raise_error(ArgumentError, /tool_use_id must be a String/)
  end

  it "rejects an empty tool_use_id" do
    expect { described_class.new(tool_use_id: "", output: "x") }
      .to raise_error(ArgumentError, /tool_use_id must not be empty/)
  end

  it "rejects having neither output nor error" do
    expect { described_class.new(tool_use_id: "toolu_1") }
      .to raise_error(ArgumentError, /exactly one of output or error/)
  end

  it "rejects having both output and error" do
    expect { described_class.new(tool_use_id: "toolu_1", output: "x", error: "y") }
      .to raise_error(ArgumentError, /exactly one of output or error/)
  end

  it "rejects a non-String output" do
    expect { described_class.new(tool_use_id: "toolu_1", output: 42) }
      .to raise_error(ArgumentError, /output must be a String/)
  end

  it "rejects a non-String error" do
    expect { described_class.new(tool_use_id: "toolu_1", error: :boom) }
      .to raise_error(ArgumentError, /error must be a String/)
  end

  it "is equal to another ToolResult with the same fields" do
    a = described_class.new(tool_use_id: "toolu_1", output: "x")
    b = described_class.new(tool_use_id: "toolu_1", output: "x")
    expect(a).to eq(b)
  end

  it "serializes to a hash via #to_h" do
    r = described_class.new(tool_use_id: "toolu_1", output: "x")
    expect(r.to_h).to eq({ tool_use_id: "toolu_1", output: "x", error: nil })
  end
end
