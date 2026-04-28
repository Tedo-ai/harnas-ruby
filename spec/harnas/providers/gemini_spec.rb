# frozen_string_literal: true

require "harnas/providers/gemini"
require "json"

RSpec.describe Harnas::Providers::Gemini do
  let(:api_key) { "test-key" }
  let(:http)    { double("http") }

  def response_double(status, body)
    double("response", status: status, body: double(to_s: body))
  end

  let(:request) do
    {
      model: "gemini-2.5-flash",
      contents: [
        { role: "user", parts: [{ text: "hi" }] }
      ]
    }
  end

  describe "#call" do
    it "POSTs to the model-specific generateContent URL with x-goog-api-key" do
      provider = described_class.new(api_key: api_key, http: http)
      body = JSON.generate(
        candidates: [
          { content: { role: "model", parts: [{ text: "hi" }] }, finishReason: "STOP" }
        ]
      )

      expected_url = "#{described_class::ENDPOINT_BASE}/gemini-2.5-flash:#{described_class::ACTION}"

      expect(http).to receive(:post).with(
        expected_url,
        hash_including(
          headers: hash_including(
            "x-goog-api-key" => api_key,
            "content-type" => "application/json"
          ),
          json: { "contents" => [{ "role" => "user", "parts" => [{ "text" => "hi" }] }] }
        )
      ).and_return(response_double(200, body))

      result = provider.call(request)
      expect(result.dig("candidates", 0, "content", "parts", 0, "text")).to eq("hi")
    end

    it "strips :model from the body before sending" do
      provider = described_class.new(api_key: api_key, http: http)
      expect(http).to receive(:post) do |_url, opts|
        expect(opts[:json]).not_to have_key("model")
        expect(opts[:json]).not_to have_key(:model)
        response_double(200, "{}")
      end

      provider.call(request)
    end

    it "raises Error when :model is missing from the request" do
      provider = described_class.new(api_key: api_key, http: http)
      expect { provider.call(contents: []) }
        .to raise_error(Harnas::Providers::Error, /must include 'model'/)
    end

    it "raises HTTPError on non-200" do
      provider = described_class.new(api_key: api_key, http: http)
      allow(http).to receive(:post).and_return(
        response_double(403, '{"error":{"message":"forbidden"}}')
      )

      expect { provider.call(request) }
        .to raise_error(Harnas::Providers::HTTPError) do |e|
          expect(e.status).to eq(403)
          expect(e.body).to eq("error" => { "message" => "forbidden" })
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
      harnas_conformance_fixture("hello-one-word", "gemini")
    end

    it "produces a response that matches the recorded response shape" do
      skip "no recorded fixture" unless File.exist?(File.join(fixture_dir, "response.json"))

      recorded_response = JSON.parse(File.read(File.join(fixture_dir, "response.json")))
      recorded_request  = JSON.parse(File.read(File.join(fixture_dir, "request.json")))

      provider = described_class.new(api_key: api_key, http: http)
      allow(http).to receive(:post).and_return(
        response_double(200, JSON.generate(recorded_response))
      )

      result = provider.call(recorded_request)
      expect(result.dig("candidates", 0, "content", "parts", 0, "text")).to be_a(String)
      expect(result.dig("candidates", 0, "finishReason")).to be_a(String)
    end
  end
end
