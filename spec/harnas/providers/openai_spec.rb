# frozen_string_literal: true

require "harnas/providers/openai"
require "json"

RSpec.describe Harnas::Providers::OpenAI do
  let(:api_key) { "test-key" }
  let(:http)    { double("http") }

  def response_double(status, body)
    double("response", status: status, body: double(to_s: body))
  end

  let(:request) do
    {
      model: "gpt-5.4-mini",
      messages: [{ role: "user", content: "hi" }]
    }
  end

  describe "#call" do
    it "POSTs to the chat completions endpoint with a Bearer token" do
      provider = described_class.new(api_key: api_key, http: http)
      body = '{"choices":[{"message":{"role":"assistant","content":"hi"}}]}'

      expect(http).to receive(:post).with(
        described_class::ENDPOINT,
        hash_including(
          headers: hash_including(
            "authorization" => "Bearer #{api_key}",
            "content-type" => "application/json"
          ),
          json: request
        )
      ).and_return(response_double(200, body))

      result = provider.call(request)
      expect(result.dig("choices", 0, "message", "content")).to eq("hi")
    end

    it "raises HTTPError on non-200" do
      provider = described_class.new(api_key: api_key, http: http)
      allow(http).to receive(:post).and_return(
        response_double(429, '{"error":{"message":"rate limited"}}')
      )

      expect { provider.call(request) }
        .to raise_error(Harnas::Providers::HTTPError) do |e|
          expect(e.status).to eq(429)
          expect(e.body).to eq("error" => { "message" => "rate limited" })
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
      File.expand_path("../../../../spec/conformance/fixtures/hello-one-word/openai", __dir__)
    end

    it "produces a response that matches the recorded response shape" do
      recorded_response = JSON.parse(File.read(File.join(fixture_dir, "response.json")))
      recorded_request  = JSON.parse(File.read(File.join(fixture_dir, "request.json")))

      provider = described_class.new(api_key: api_key, http: http)
      allow(http).to receive(:post).and_return(
        response_double(200, JSON.generate(recorded_response))
      )

      result = provider.call(recorded_request)
      expect(result.dig("choices", 0, "message", "content")).to be_a(String)
      expect(result.dig("choices", 0, "finish_reason")).to be_a(String)
    end
  end
end
