# frozen_string_literal: true

require "harnas/events/user_message"

RSpec.describe Harnas::Events::UserMessage do
  it "holds the text" do
    expect(described_class.new(text: "hi").text).to eq("hi")
  end

  it "is frozen (immutable)" do
    expect(described_class.new(text: "hi")).to be_frozen
  end

  it "rejects a non-String text" do
    expect { described_class.new(text: 1) }
      .to raise_error(ArgumentError, /text must be a String/)
  end

  it "rejects empty text" do
    expect { described_class.new(text: "") }
      .to raise_error(ArgumentError, /text must not be empty/)
  end

  it "is equal to another UserMessage with the same text" do
    expect(described_class.new(text: "x")).to eq(described_class.new(text: "x"))
  end

  it "serializes to a hash via #to_h" do
    expect(described_class.new(text: "hi").to_h).to eq({ text: "hi" })
  end
end
