# frozen_string_literal: true

require "harnas/conformance/scripted_stream_provider"

RSpec.describe Harnas::Conformance::ScriptedStreamProvider do
  it "yields one normalized event at a time" do
    provider = described_class.new(
      streams: [
        [
          {
            "type" => "assistant_message",
            "payload" => {
              "text" => "ok",
              "stop_reason" => "end_turn",
              "usage" => { "input_tokens" => 1, "output_tokens" => 1 }
            }
          }
        ]
      ]
    )

    events = []
    provider.call({}) { |event| events << event }

    expect(events).to eq([
                           {
                             type: :assistant_message,
                             payload: {
                               text: "ok",
                               stop_reason: :end_turn,
                               usage: { input_tokens: 1, output_tokens: 1 }
                             }
                           }
                         ])
  end
end
