# frozen_string_literal: true

require "harnas/providers/mock"
require "json"
require "tmpdir"
require "fileutils"

RSpec.describe Harnas::Providers::Mock do
  let(:fixture_dir) { Dir.mktmpdir("harnas-mock-") }
  after             { FileUtils.rm_rf(fixture_dir) }

  let(:recorded_request) do
    { "model" => "x", "messages" => [{ "role" => "user", "content" => "hi" }] }
  end
  let(:recorded_response) do
    { "content" => [{ "type" => "text", "text" => "hi" }] }
  end

  def write_fixture(req: recorded_request, res: recorded_response)
    File.write(File.join(fixture_dir, "request.json"),  JSON.generate(req))
    File.write(File.join(fixture_dir, "response.json"), JSON.generate(res))
  end

  describe "#initialize" do
    it "loads the recorded fixture on construction" do
      write_fixture
      provider = described_class.new(fixture_path: fixture_dir)

      expect(provider.recorded_request).to eq(recorded_request)
      expect(provider.recorded_response).to eq(recorded_response)
    end

    it "raises FixtureError when files are missing" do
      expect { described_class.new(fixture_path: fixture_dir) }
        .to raise_error(Harnas::Providers::FixtureError, /missing/)
    end

    it "raises FixtureError on invalid JSON" do
      File.write(File.join(fixture_dir, "request.json"), "not json")
      File.write(File.join(fixture_dir, "response.json"), "{}")

      expect { described_class.new(fixture_path: fixture_dir) }
        .to raise_error(Harnas::Providers::FixtureError, /invalid JSON/)
    end
  end

  describe "#call" do
    it "returns the recorded response when the request matches" do
      write_fixture
      provider = described_class.new(fixture_path: fixture_dir)

      expect(provider.call(recorded_request)).to eq(recorded_response)
    end

    it "normalizes symbol/string keys when matching" do
      write_fixture
      provider = described_class.new(fixture_path: fixture_dir)
      symbolic = { model: "x", messages: [{ role: "user", content: "hi" }] }

      expect(provider.call(symbolic)).to eq(recorded_response)
    end

    it "raises FixtureError on request mismatch in strict mode" do
      write_fixture
      provider = described_class.new(fixture_path: fixture_dir)

      expect { provider.call("model" => "different") }
        .to raise_error(Harnas::Providers::FixtureError, /does not match/)
    end

    it "ignores request content in non-strict mode" do
      write_fixture
      provider = described_class.new(fixture_path: fixture_dir, strict: false)

      expect(provider.call("totally" => "different")).to eq(recorded_response)
    end
  end
end
