# frozen_string_literal: true

require "harnas/providers/anthropic"
require "json"

RSpec.describe Harnas::Providers::Anthropic do
  let(:api_key) { "test-key" }
  let(:http)    { double("http") }

  def response_double(status, body)
    double("response", status: status, body: double(to_s: body))
  end

  let(:request) do
    {
      model: "claude-sonnet-4-5",
      max_tokens: 1024,
      messages: [{ role: "user", content: "hi" }]
    }
  end

  describe "#call" do
    it "POSTs to the messages endpoint with auth and version headers" do
      provider = described_class.new(api_key: api_key, http: http)
      body = '{"content":[{"type":"text","text":"hi"}]}'

      expect(http).to receive(:post).with(
        described_class::ENDPOINT,
        hash_including(
          headers: hash_including(
            "x-api-key" => api_key,
            "anthropic-version" => described_class::DEFAULT_API_VERSION,
            "content-type" => "application/json"
          ),
          json: request
        )
      ).and_return(response_double(200, body))

      result = provider.call(request)
      expect(result).to eq("content" => [{ "type" => "text", "text" => "hi" }])
    end

    it "uses the configured api_version when provided" do
      provider = described_class.new(api_key: api_key, api_version: "2099-01-01", http: http)

      expect(http).to receive(:post).with(
        described_class::ENDPOINT,
        hash_including(headers: hash_including("anthropic-version" => "2099-01-01"))
      ).and_return(response_double(200, "{}"))

      provider.call(request)
    end

    it "raises HTTPError on non-200" do
      provider = described_class.new(api_key: api_key, http: http)
      allow(http).to receive(:post).and_return(
        response_double(401, '{"error":{"message":"unauthorized"}}')
      )

      expect { provider.call(request) }
        .to raise_error(Harnas::Providers::HTTPError) do |e|
          expect(e.status).to eq(401)
          expect(e.body).to eq("error" => { "message" => "unauthorized" })
        end
    end

    it "raises Error on invalid JSON response" do
      provider = described_class.new(api_key: api_key, http: http)
      allow(http).to receive(:post).and_return(response_double(200, "not json"))

      expect { provider.call(request) }
        .to raise_error(Harnas::Providers::Error, /invalid JSON/)
    end
  end

  describe "conformance against recorded fixture" do
    let(:fixture_dir) do
      harnas_conformance_fixture("hello-one-word", "anthropic")
    end

    it "produces a response that matches the recorded response shape" do
      recorded_response = JSON.parse(File.read(File.join(fixture_dir, "response.json")))
      recorded_request  = JSON.parse(File.read(File.join(fixture_dir, "request.json")))

      provider = described_class.new(api_key: api_key, http: http)
      allow(http).to receive(:post).and_return(
        response_double(200, JSON.generate(recorded_response))
      )

      result = provider.call(recorded_request)
      expect(result.dig("content", 0, "text")).to be_a(String)
      expect(result["stop_reason"]).to be_a(String)
    end
  end
end
