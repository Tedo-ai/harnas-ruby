# frozen_string_literal: true

require "harnas/providers/gemini_stream"

class FakeGeminiSSEResponse
  attr_reader :code

  def initialize(body_chunks, code: "200")
    @chunks = body_chunks
    @code   = code
  end

  def read_body(&block)
    if block
      @chunks.each { |c| block.call(c) }
    else
      @chunks.join
    end
  end
end

RSpec.describe Harnas::Providers::GeminiStream do
  let(:stream) { described_class.new(api_key: "test") }
  let(:request) do
    { model: "gemini-flash-latest", contents: [] }
  end

  def with_stubbed_http(sse_body)
    response = FakeGeminiSSEResponse.new(sse_body.scan(/.{1,64}/m))
    allow_any_instance_of(Net::HTTP).to receive(:request) do |_http, _req, &block|
      block.call(response)
    end
    yield
  end

  describe "text-only stream" do
    let(:sse) do
      <<~SSE
        data: {"candidates":[{"content":{"parts":[{"text":"Hel"}],"role":"model"}}]}

        data: {"candidates":[{"content":{"parts":[{"text":"lo"}],"role":"model"}}]}

        data: {"candidates":[{"content":{"parts":[{"text":""}],"role":"model"},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":5,"candidatesTokenCount":2}}

      SSE
    end

    it "yields the canonical event sequence in order" do
      events = []
      with_stubbed_http(sse) { stream.call(request) { |e| events << e } }

      expect(events.map { |e| e[:type] }).to eq(%i[
                                                  assistant_turn_started
                                                  assistant_text_delta
                                                  assistant_text_delta
                                                  assistant_turn_completed
                                                  assistant_message
                                                ])
    end

    it "concatenates text chunks into the consolidated :assistant_message" do
      events = []
      with_stubbed_http(sse) { stream.call(request) { |e| events << e } }

      consolidated = events.find { |e| e[:type] == :assistant_message }
      expect(consolidated[:payload][:text]).to eq("Hello")
      expect(consolidated[:payload][:stop_reason]).to eq(:end_turn)
    end

    it "extracts usage into the normalized fields" do
      events = []
      with_stubbed_http(sse) { stream.call(request) { |e| events << e } }

      completed = events.find { |e| e[:type] == :assistant_turn_completed }
      expect(completed[:payload][:usage])
        .to eq({ input_tokens: 5, output_tokens: 2 })
    end
  end

  describe "function_call stream" do
    let(:sse) do
      <<~SSE
        data: {"candidates":[{"content":{"parts":[{"functionCall":{"name":"echo","args":{"text":"hi"}}}],"role":"model"},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":5,"candidatesTokenCount":3}}

      SSE
    end

    it "emits :tool_use_begin + :tool_use_end for the complete function call" do
      events = []
      with_stubbed_http(sse) { stream.call(request) { |e| events << e } }

      types = events.map { |e| e[:type] }
      expect(types).to include(:tool_use_begin, :tool_use_end)
      expect(types.index(:tool_use_begin)).to be < types.index(:tool_use_end)
    end

    it "consolidates to :assistant_message + :tool_use with assembled args" do
      events = []
      with_stubbed_http(sse) { stream.call(request) { |e| events << e } }

      tool_use = events.find { |e| e[:type] == :tool_use }
      expect(tool_use[:payload][:name]).to eq("echo")
      expect(tool_use[:payload][:arguments]).to eq({ text: "hi" })
    end
  end

  describe "error handling" do
    it "yields :assistant_turn_failed and re-raises on HTTP error" do
      response = FakeGeminiSSEResponse.new(['{"error":{"message":"bad"}}'], code: "400")
      allow_any_instance_of(Net::HTTP).to receive(:request) do |_http, _req, &block|
        block.call(response)
      end

      events = []
      expect do
        stream.call(request) { |e| events << e }
      end.to raise_error(Harnas::Providers::HTTPError)

      expect(events.find { |e| e[:type] == :assistant_turn_failed }).not_to be_nil
    end
  end
end
