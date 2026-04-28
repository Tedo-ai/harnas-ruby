# frozen_string_literal: true

require "harnas/ingestors/anthropic"
require "json"

RSpec.describe Harnas::Ingestors::Anthropic do
  let(:ingestor) { described_class.new }

  let(:text_only_response) do
    {
      "content" => [{ "type" => "text", "text" => "Hello" }],
      "stop_reason" => "end_turn",
      "usage" => { "input_tokens" => 12, "output_tokens" => 4 }
    }
  end

  let(:tool_use_response) do
    {
      "content" => [
        { "type" => "text", "text" => "I'll use the echo tool." },
        { "type" => "tool_use", "id" => "toolu_1", "name" => "echo", "input" => { "text" => "hi" } }
      ],
      "stop_reason" => "tool_use",
      "usage" => { "input_tokens" => 20, "output_tokens" => 10 }
    }
  end

  describe "text-only response" do
    it "returns exactly one :assistant_message event" do
      events = ingestor.call(text_only_response)
      expect(events.size).to eq(1)
      expect(events.first[:type]).to eq(:assistant_message)
    end

    it "carries text, normalized stop_reason, and normalized usage in the payload" do
      events  = ingestor.call(text_only_response)
      payload = events.first[:payload]
      expect(payload[:text]).to eq("Hello")
      expect(payload[:stop_reason]).to eq(:end_turn)
      expect(payload[:usage]).to eq({ input_tokens: 12, output_tokens: 4 })
    end

    it "normalizes the wire stop_reason vocabulary" do
      {
        "end_turn" => :end_turn,
        "max_tokens" => :max_tokens,
        "tool_use" => :tool_use,
        "stop_sequence" => :stop_sequence,
        "refusal" => :refusal
      }.each do |wire, neutral|
        response = text_only_response.merge("stop_reason" => wire)
        expect(ingestor.call(response).first[:payload][:stop_reason]).to eq(neutral)
      end
    end

    it "maps unknown stop_reason values to :other" do
      response = text_only_response.merge("stop_reason" => "exotic_new_reason")
      expect(ingestor.call(response).first[:payload][:stop_reason]).to eq(:other)
    end

    it "defaults missing usage fields to 0" do
      response = text_only_response.merge("usage" => {})
      expect(ingestor.call(response).first[:payload][:usage])
        .to eq({ input_tokens: 0, output_tokens: 0 })
    end
  end

  describe "tool_use response" do
    it "emits one :assistant_message plus one :tool_use per tool_use block" do
      events = ingestor.call(tool_use_response)
      expect(events.map { |e| e[:type] }).to eq(%i[assistant_message tool_use])
    end

    it "concatenates text blocks into the assistant_message text" do
      events = ingestor.call(tool_use_response)
      expect(events[0][:payload][:text]).to eq("I'll use the echo tool.")
    end

    it "carries stop_reason :tool_use on the assistant_message" do
      events = ingestor.call(tool_use_response)
      expect(events[0][:payload][:stop_reason]).to eq(:tool_use)
    end

    it "extracts id, name, and symbol-keyed arguments into the :tool_use event" do
      events  = ingestor.call(tool_use_response)
      payload = events[1][:payload]
      expect(payload[:id]).to eq("toolu_1")
      expect(payload[:name]).to eq("echo")
      expect(payload[:arguments]).to eq({ text: "hi" })
    end

    it "emits an assistant_message with empty text when the response has only tool_use blocks" do
      response = tool_use_response.merge(
        "content" => [{ "type" => "tool_use", "id" => "toolu_1", "name" => "echo", "input" => {} }]
      )
      events = ingestor.call(response)
      expect(events[0][:payload][:text]).to eq("")
      expect(events[1][:type]).to eq(:tool_use)
    end
  end

  describe "conformance against recorded fixture" do
    let(:fixture_path) do
      harnas_conformance_fixture("hello-one-word", "anthropic", "response.json")
    end

    it "produces a valid assistant_message event from the recorded response" do
      recorded = JSON.parse(File.read(fixture_path))
      events   = ingestor.call(recorded)

      expect(events.size).to eq(1)
      expect(events.first[:type]).to eq(:assistant_message)
      payload = events.first[:payload]
      expect(payload[:text]).to be_a(String)
      expect(payload[:text]).not_to be_empty
      expect(payload[:stop_reason]).to eq(:end_turn)
      expect(payload[:usage][:input_tokens]).to be_positive
      expect(payload[:usage][:output_tokens]).to be_positive
    end
  end
end
