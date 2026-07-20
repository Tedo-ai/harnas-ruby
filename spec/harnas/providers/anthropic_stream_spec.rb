# frozen_string_literal: true

require "harnas/providers/anthropic_stream"

# A fake Net::HTTP response that feeds a canned SSE body chunk-by-chunk.
class FakeSSEResponse
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

RSpec.describe Harnas::Providers::AnthropicStream do
  let(:stream) { described_class.new(api_key: "test") }
  let(:request) { { model: "claude-sonnet-4-5", max_tokens: 16, messages: [] } }

  # Helper: stub the HTTP layer so #call reads the given SSE body.
  def with_stubbed_http(sse_body)
    chunks = sse_body.scan(/.{1,64}/m) # chunk the body
    response = FakeSSEResponse.new(chunks)

    allow_any_instance_of(Net::HTTP).to receive(:request) do |_http, _req, &block|
      block.call(response)
    end
    yield
  end

  describe "text-only stream" do
    let(:sse) do
      <<~SSE
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_1","usage":{"input_tokens":5,"output_tokens":0}}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"lo"}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":2}}

        event: message_stop
        data: {"type":"message_stop"}

      SSE
    end

    it "yields the canonical event sequence in order" do
      events = []
      with_stubbed_http(sse) do
        stream.call(request) { |e| events << e }
      end

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
      with_stubbed_http(sse) do
        stream.call(request) { |e| events << e }
      end

      consolidated = events.find { |e| e[:type] == :assistant_message }
      expect(consolidated[:payload][:text]).to eq("Hello")
      expect(consolidated[:payload][:stop_reason]).to eq(:end_turn)
    end

    it ":assistant_turn_completed carries the normalized stop_reason and usage" do
      events = []
      with_stubbed_http(sse) do
        stream.call(request) { |e| events << e }
      end

      completed = events.find { |e| e[:type] == :assistant_turn_completed }
      expect(completed[:payload][:stop_reason]).to eq(:end_turn)
      expect(completed[:payload][:usage][:output_tokens]).to eq(2)
    end

    it "uses the same turn_id across all events" do
      events = []
      with_stubbed_http(sse) do
        stream.call(request) { |e| events << e }
      end

      turn_ids = events
                 .map { |e| e[:payload][:turn_id] }
                 .compact
                 .uniq
      expect(turn_ids.size).to eq(1)
    end
  end

  describe "tool_use stream" do
    let(:sse) do
      <<~SSE
        event: message_start
        data: {"type":"message_start","message":{"usage":{"input_tokens":4,"output_tokens":0}}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"echo","input":{}}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"text"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"\\": \\"hi\\"}"}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":12}}

        event: message_stop
        data: {"type":"message_stop"}

      SSE
    end

    it "emits :tool_use_begin, :tool_use_argument_delta(s), :tool_use_end in order" do
      events = []
      with_stubbed_http(sse) do
        stream.call(request) { |e| events << e }
      end

      types = events.map { |e| e[:type] }
      expect(types).to include(:tool_use_begin, :tool_use_argument_delta, :tool_use_end)
      expect(types.index(:tool_use_begin)).to be < types.index(:tool_use_argument_delta)
      expect(types.index(:tool_use_argument_delta)).to be < types.index(:tool_use_end)
    end

    it "consolidates to :assistant_message with empty text + :tool_use with args" do
      events = []
      with_stubbed_http(sse) do
        stream.call(request) { |e| events << e }
      end

      tool_use = events.find { |e| e[:type] == :tool_use }
      expect(tool_use[:payload][:id]).to eq("toolu_1")
      expect(tool_use[:payload][:name]).to eq("echo")
      expect(tool_use[:payload][:arguments]).to eq({ text: "hi" })

      assistant = events.find { |e| e[:type] == :assistant_message }
      expect(assistant[:payload][:text]).to eq("")
      expect(assistant[:payload][:stop_reason]).to eq(:tool_use)
    end
  end

  describe "error handling" do
    it "yields :assistant_turn_failed and re-raises on HTTP error" do
      error_body = JSON.generate(error: { message: "rate limited" })
      response   = FakeSSEResponse.new([error_body], code: "429")
      allow_any_instance_of(Net::HTTP).to receive(:request) do |_http, _req, &block|
        block.call(response)
      end

      events = []
      expect do
        stream.call(request) { |e| events << e }
      end.to raise_error(Harnas::Providers::HTTPError)

      failed = events.find { |e| e[:type] == :assistant_turn_failed }
      expect(failed).not_to be_nil
      expect(failed[:payload][:error]).to match(/HTTPError/)
    end
  end
end
