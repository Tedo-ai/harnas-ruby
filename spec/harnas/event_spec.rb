# frozen_string_literal: true

require "harnas/event"

RSpec.describe Harnas::Event do
  def make(**overrides)
    defaults = { seq: 0, id: "evt_0", type: :user_message, payload: { text: "hi" } }
    described_class.new(**defaults, **overrides)
  end

  it "holds seq, id, type, and payload" do
    event = make
    expect(event.seq).to eq(0)
    expect(event.id).to eq("evt_0")
    expect(event.type).to eq(:user_message)
    expect(event.payload).to eq({ text: "hi" })
  end

  it "is frozen (immutable)" do
    expect(make).to be_frozen
  end

  it "rejects a non-Integer seq" do
    expect { make(seq: "0") }.to raise_error(ArgumentError, /seq must be an Integer/)
  end

  it "rejects a non-Symbol type" do
    expect { make(type: "user_message") }.to raise_error(ArgumentError, /type must be a Symbol/)
  end

  it "rejects a non-Hash payload" do
    expect { make(payload: []) }.to raise_error(ArgumentError, /payload must be a Hash/)
  end

  it "is equal to another Event with the same fields" do
    expect(make).to eq(make)
  end
end
