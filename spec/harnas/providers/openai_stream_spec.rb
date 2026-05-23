# frozen_string_literal: true

require "harnas/providers/openai_stream"

class FakeSSEChunkResponse
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

RSpec.describe Harnas::Providers::OpenAIStream do
  let(:stream) { described_class.new(api_key: "test") }
  let(:request) { { model: "gpt-5.4-mini", messages: [] } }

  def with_stubbed_http(sse_body)
    response = FakeSSEChunkResponse.new(sse_body.scan(/.{1,64}/m))
    allow_any_instance_of(Net::HTTP).to receive(:request) do |_http, _req, &block|
      block.call(response)
    end
    yield
  end

  describe "text-only stream" do
    let(:sse) do
      <<~SSE
        data: {"choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}

        data: {"choices":[{"index":0,"delta":{"content":"Hel"},"finish_reason":null}]}

        data: {"choices":[{"index":0,"delta":{"content":"lo"},"finish_reason":null}]}

        data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":5,"completion_tokens":2}}

        data: [DONE]

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
      expect(consolidated[:payload][:usage])
        .to include(input_tokens: 5, output_tokens: 2, total_tokens: 7,
                    provenance: "provider_reported")
    end

    it "ignores the [DONE] sentinel" do
      expect do
        with_stubbed_http(sse) { stream.call(request) { |_e| nil } }
      end.not_to raise_error
    end
  end

  describe "tool_use stream" do
    let(:sse) do
      <<~SSE
        data: {"choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}

        data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_abc","type":"function","function":{"name":"echo","arguments":""}}]},"finish_reason":null}]}

        data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"t"}}]},"finish_reason":null}]}

        data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"ext\\":\\"hi\\"}"}}]},"finish_reason":null}]}

        data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}

        data: [DONE]

      SSE
    end

    it "emits tool_use_begin, tool_use_argument_delta(s), tool_use_end in order" do
      events = []
      with_stubbed_http(sse) { stream.call(request) { |e| events << e } }

      types = events.map { |e| e[:type] }
      expect(types).to include(:tool_use_begin, :tool_use_argument_delta, :tool_use_end)
      expect(types.index(:tool_use_begin)).to be < types.index(:tool_use_argument_delta)
      expect(types.index(:tool_use_argument_delta)).to be < types.index(:tool_use_end)
    end

    it "consolidates to :assistant_message with empty text + :tool_use with args" do
      events = []
      with_stubbed_http(sse) { stream.call(request) { |e| events << e } }

      tool_use = events.find { |e| e[:type] == :tool_use }
      expect(tool_use[:payload][:id]).to eq("call_abc")
      expect(tool_use[:payload][:name]).to eq("echo")
      expect(tool_use[:payload][:arguments]).to eq({ text: "hi" })

      expect(events.find { |e| e[:type] == :assistant_message }[:payload][:stop_reason])
        .to eq(:tool_use)
    end
  end

  describe "error handling" do
    it "yields :assistant_turn_failed and re-raises on HTTP error" do
      response = FakeSSEChunkResponse.new(['{"error":{"message":"rate limited"}}'], code: "429")
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
