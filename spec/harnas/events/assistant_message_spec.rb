# frozen_string_literal: true

require "harnas/events/assistant_message"

RSpec.describe Harnas::Events::AssistantMessage do
  def make(**overrides)
    defaults = { text: "hi", stop_reason: :end_turn, usage: { input_tokens: 1, output_tokens: 1 } }
    described_class.new(**defaults, **overrides)
  end

  it "holds text, stop_reason, and usage" do
    msg = make
    expect(msg.text).to eq("hi")
    expect(msg.stop_reason).to eq(:end_turn)
    expect(msg.usage).to eq({ input_tokens: 1, output_tokens: 1 })
  end

  it "is frozen (immutable)" do
    expect(make).to be_frozen
  end

  it "defaults usage to an empty Hash" do
    msg = described_class.new(text: "hi", stop_reason: :end_turn)
    expect(msg.usage).to eq({})
  end

  it "rejects a non-String text" do
    expect { make(text: 1) }.to raise_error(ArgumentError, /text must be a String/)
  end

  it "rejects a non-Symbol stop_reason" do
    expect { make(stop_reason: "end_turn") }
      .to raise_error(ArgumentError, /stop_reason must be a Symbol/)
  end

  it "rejects an unknown stop_reason" do
    expect { make(stop_reason: :ran_out_of_pixie_dust) }
      .to raise_error(ArgumentError, /stop_reason must be one of/)
  end

  it "accepts every allowed stop_reason" do
    %i[end_turn max_tokens tool_use stop_sequence refusal other].each do |sr|
      expect { make(stop_reason: sr) }.not_to raise_error
    end
  end

  it "rejects a non-Hash usage" do
    expect { make(usage: nil) }.to raise_error(ArgumentError, /usage must be a Hash/)
  end

  it "is equal to another AssistantMessage with the same fields" do
    expect(make).to eq(make)
  end

  it "serializes to a hash via #to_h" do
    expect(make.to_h).to eq({ text: "hi", stop_reason: :end_turn,
                              usage: { input_tokens: 1, output_tokens: 1 } })
  end
end
