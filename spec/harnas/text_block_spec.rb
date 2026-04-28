# frozen_string_literal: true

require "harnas/text_block"

RSpec.describe Harnas::TextBlock do
  it "holds a text string" do
    block = described_class.new(text: "hello")
    expect(block.text).to eq("hello")
  end

  it "is frozen (immutable)" do
    block = described_class.new(text: "hello")
    expect(block).to be_frozen
  end

  it "rejects a non-string text" do
    expect { described_class.new(text: 123) }
      .to raise_error(ArgumentError, /text must be a String/)
  end

  it "rejects an empty text" do
    expect { described_class.new(text: "") }
      .to raise_error(ArgumentError, /text must not be empty/)
  end

  it "is equal to another TextBlock with the same text" do
    a = described_class.new(text: "hi")
    b = described_class.new(text: "hi")
    expect(a).to eq(b)
  end
end
