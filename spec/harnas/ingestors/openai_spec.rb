# frozen_string_literal: true

require "harnas/ingestors/openai"
require "json"

RSpec.describe Harnas::Ingestors::OpenAI do
  let(:ingestor) { described_class.new }

  let(:minimal_response) do
    {
      "choices" => [{
        "message" => { "role" => "assistant", "content" => "Hello" },
        "finish_reason" => "stop"
      }],
      "usage" => { "prompt_tokens" => 11, "completion_tokens" => 4, "total_tokens" => 15 }
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

  it "extracts the text from choices[0].message.content" do
    expect(payload_of(minimal_response)[:text]).to eq("Hello")
  end

  it "normalizes 'stop' to :end_turn" do
    expect(payload_of(minimal_response)[:stop_reason]).to eq(:end_turn)
  end

  it "normalizes the wire finish_reason vocabulary" do
    {
      "stop" => :end_turn,
      "length" => :max_tokens,
      "tool_calls" => :tool_use,
      "function_call" => :tool_use,
      "content_filter" => :refusal
    }.each do |wire, neutral|
      response = minimal_response.dup
      response["choices"] = [response["choices"][0].merge("finish_reason" => wire)]
      expect(payload_of(response)[:stop_reason]).to eq(neutral)
    end
  end

  it "maps unknown finish_reason values to :other" do
    response = minimal_response.dup
    response["choices"] = [response["choices"][0].merge("finish_reason" => "newish")]
    expect(payload_of(response)[:stop_reason]).to eq(:other)
  end

  it "extracts prompt_tokens as input_tokens and completion_tokens as output_tokens" do
    expect(payload_of(minimal_response)[:usage]).to eq({ input_tokens: 11, output_tokens: 4 })
  end

  it "defaults missing usage fields to 0" do
    response = minimal_response.merge("usage" => {})
    expect(payload_of(response)[:usage]).to eq({ input_tokens: 0, output_tokens: 0 })
  end

  it "raises when there are no choices" do
    expect { ingestor.call(minimal_response.merge("choices" => [])) }
      .to raise_error(ArgumentError, /no choices/)
  end

  it "emits an assistant_message with empty text when content is null and tool_calls are present" do
    response = minimal_response.merge(
      "choices" => [{
        "message" => {
          "role" => "assistant",
          "content" => nil,
          "tool_calls" => [{
            "id" => "call_1",
            "type" => "function",
            "function" => { "name" => "get_current_time", "arguments" => "{}" }
          }]
        },
        "finish_reason" => "tool_calls"
      }]
    )
    events = ingestor.call(response)
    expect(events.first[:type]).to eq(:assistant_message)
    expect(events.first[:payload][:text]).to eq("")
    expect(events.first[:payload][:stop_reason]).to eq(:tool_use)
  end

  describe "tool_calls extraction" do
    let(:tool_call_response) do
      {
        "choices" => [{
          "message" => {
            "role" => "assistant",
            "content" => nil,
            "tool_calls" => [{
              "id" => "call_abc123",
              "type" => "function",
              "function" => {
                "name" => "get_current_time",
                "arguments" => '{"tz":"UTC"}'
              }
            }]
          },
          "finish_reason" => "tool_calls"
        }],
        "usage" => { "prompt_tokens" => 14, "completion_tokens" => 8 }
      }
    end

    it "emits one :tool_use event per tool_calls entry, after the assistant_message" do
      events = ingestor.call(tool_call_response)
      expect(events.map { |e| e[:type] }).to eq(%i[assistant_message tool_use])
    end

    it "parses the id, name, and arguments from the tool_calls entry" do
      payload = ingestor.call(tool_call_response).last[:payload]
      expect(payload[:id]).to eq("call_abc123")
      expect(payload[:name]).to eq("get_current_time")
      expect(payload[:arguments]).to eq({ tz: "UTC" })
    end

    it "treats an empty arguments string as {}" do
      response = tool_call_response.dup
      response["choices"][0]["message"]["tool_calls"][0]["function"]["arguments"] = ""
      expect(ingestor.call(response).last[:payload][:arguments]).to eq({})
    end

    it "emits multiple :tool_use events when the assistant requests multiple tool calls" do
      response = tool_call_response.dup
      response["choices"][0]["message"]["tool_calls"] = [
        { "id" => "call_1", "type" => "function",
          "function" => { "name" => "get_current_time", "arguments" => "{}" } },
        { "id" => "call_2", "type" => "function",
          "function" => { "name" => "get_current_time", "arguments" => "{}" } }
      ]
      events = ingestor.call(response)
      expect(events.map { |e| e[:type] }).to eq(%i[assistant_message tool_use tool_use])
      expect(events[1][:payload][:id]).to eq("call_1")
      expect(events[2][:payload][:id]).to eq("call_2")
    end
  end

  describe "conformance against recorded fixture" do
    let(:fixture_path) do
      File.expand_path(
        "../../../../spec/conformance/fixtures/hello-one-word/openai/response.json",
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
      expect(payload[:usage][:output_tokens]).to be_positive
    end
  end
end
