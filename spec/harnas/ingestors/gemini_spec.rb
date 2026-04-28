# frozen_string_literal: true

require "harnas/ingestors/gemini"
require "json"

RSpec.describe Harnas::Ingestors::Gemini do
  let(:ingestor) { described_class.new }

  let(:minimal_response) do
    {
      "candidates" => [{
        "content" => {
          "role" => "model",
          "parts" => [{ "text" => "Hello" }]
        },
        "finishReason" => "STOP"
      }],
      "usageMetadata" => {
        "promptTokenCount" => 6,
        "candidatesTokenCount" => 4,
        "totalTokenCount" => 10
      }
    }
  end

  def payload_of(response)
    ingestor.call(response).first[:payload]
  end

  it "returns exactly one :assistant_message event" do
    events = ingestor.call(minimal_response)
    expect(events.size).to eq(1)
    expect(events.first[:type]).to eq(:assistant_message)
  end

  it "extracts the text from candidates[0].content.parts[0].text" do
    expect(payload_of(minimal_response)[:text]).to eq("Hello")
  end

  it "normalizes 'STOP' to :end_turn" do
    expect(payload_of(minimal_response)[:stop_reason]).to eq(:end_turn)
  end

  it "normalizes the wire finishReason vocabulary" do
    {
      "STOP" => :end_turn,
      "MAX_TOKENS" => :max_tokens,
      "SAFETY" => :refusal,
      "RECITATION" => :refusal,
      "OTHER" => :other
    }.each do |wire, neutral|
      response = minimal_response.dup
      response["candidates"] = [response["candidates"][0].merge("finishReason" => wire)]
      expect(payload_of(response)[:stop_reason]).to eq(neutral)
    end
  end

  it "maps unknown finishReason values to :other" do
    response = minimal_response.dup
    response["candidates"] = [response["candidates"][0].merge("finishReason" => "EXOTIC")]
    expect(payload_of(response)[:stop_reason]).to eq(:other)
  end

  it "extracts promptTokenCount and candidatesTokenCount into the neutral usage" do
    expect(payload_of(minimal_response)[:usage]).to eq({ input_tokens: 6, output_tokens: 4 })
  end

  it "defaults missing usage fields to 0" do
    response = minimal_response.merge("usageMetadata" => {})
    expect(payload_of(response)[:usage]).to eq({ input_tokens: 0, output_tokens: 0 })
  end

  it "raises when there are no candidates" do
    expect { ingestor.call(minimal_response.merge("candidates" => [])) }
      .to raise_error(ArgumentError, /no candidates/)
  end

  it "emits an assistant_message with empty text when the model returns only a functionCall" do
    response = minimal_response.merge(
      "candidates" => [{
        "content" => {
          "role" => "model",
          "parts" => [{ "functionCall" => { "name" => "get_current_time", "args" => {} } }]
        },
        "finishReason" => "STOP"
      }]
    )
    events = ingestor.call(response)
    expect(events.first[:type]).to eq(:assistant_message)
    expect(events.first[:payload][:text]).to eq("")
    expect(events.first[:payload][:stop_reason]).to eq(:tool_use)
  end

  describe "functionCall extraction" do
    let(:tool_call_response) do
      {
        "candidates" => [{
          "content" => {
            "role" => "model",
            "parts" => [{
              "functionCall" => { "name" => "get_current_time", "args" => { "tz" => "UTC" } }
            }]
          },
          "finishReason" => "STOP"
        }],
        "usageMetadata" => { "promptTokenCount" => 6, "candidatesTokenCount" => 4 }
      }
    end

    it "emits one :tool_use event per functionCall part, after the assistant_message" do
      events = ingestor.call(tool_call_response)
      expect(events.map { |e| e[:type] }).to eq(%i[assistant_message tool_use])
    end

    it "preserves the function name and synthesizes a deterministic :id on :tool_use" do
      payload = ingestor.call(tool_call_response).last[:payload]
      expect(payload[:name]).to eq("get_current_time")
      expect(payload[:id]).to eq("gemini.get_current_time.0")
    end

    it "produces distinct :ids for repeated calls via a per-instance counter" do
      a = ingestor.call(tool_call_response).last[:payload][:id]
      b = ingestor.call(tool_call_response).last[:payload][:id]
      expect(a).to eq("gemini.get_current_time.0")
      expect(b).to eq("gemini.get_current_time.1")
    end

    it "passes through the args hash with symbol keys" do
      payload = ingestor.call(tool_call_response).last[:payload]
      expect(payload[:arguments]).to eq({ tz: "UTC" })
    end

    it "treats missing args as {}" do
      response = tool_call_response.dup
      response["candidates"][0]["content"]["parts"][0]["functionCall"].delete("args")
      expect(ingestor.call(response).last[:payload][:arguments]).to eq({})
    end

    it "emits a thoughtSignature :annotation right after the :tool_use when present" do
      signed = tool_call_response.dup
      signed["candidates"][0]["content"]["parts"][0]["thoughtSignature"] = "sig-abc"

      events = ingestor.call(signed)
      expect(events.map { |e| e[:type] }).to eq(
        %i[assistant_message tool_use annotation]
      )
      annotation = events.last
      expect(annotation[:payload][:kind]).to eq("gemini.thought_signature")
      expect(annotation[:payload][:data]).to eq(
        { name: "get_current_time", signature: "sig-abc" }
      )
    end

    it "does not emit an annotation when no thoughtSignature is present" do
      events = ingestor.call(tool_call_response)
      expect(events.map { |e| e[:type] }).to eq(%i[assistant_message tool_use])
    end
  end

  describe "conformance against recorded fixture" do
    let(:fixture_path) do
      File.expand_path(
        "../../../../spec/conformance/fixtures/hello-one-word/gemini/response.json",
        __dir__
      )
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
    end
  end
end
