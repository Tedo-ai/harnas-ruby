# frozen_string_literal: true

require "harnas/mcp/content"

RSpec.describe Harnas::MCP::Content do
  describe ".flatten" do
    it "joins text content with blank lines" do
      content = [
        { "type" => "text", "text" => "first" },
        { "type" => "text", "text" => "second" }
      ]

      expect(described_class.flatten(content)).to eq("first\n\nsecond")
    end

    it "renders image placeholders with decoded byte counts" do
      content = [{ "type" => "image", "mimeType" => "image/png", "data" => "aGVsbG8=" }]

      expect(described_class.flatten(content)).to eq("[image: image/png, 5 bytes]")
    end

    it "falls back to encoded image length when base64 decoding fails" do
      content = [{ "type" => "image", "mimeType" => "image/png", "data" => "not base64!" }]

      expect(described_class.flatten(content)).to eq("[image: image/png, 11 bytes]")
    end

    it "renders resource placeholders" do
      content = [{ "type" => "resource", "uri" => "file:///story.md" }]

      expect(described_class.flatten(content)).to eq("[resource: file:///story.md]")
    end

    it "renders unknown content types as placeholders" do
      content = [{ "type" => "audio" }]

      expect(described_class.flatten(content)).to eq("[audio]")
    end

    it "returns an empty string for empty or nil content" do
      expect(described_class.flatten([])).to eq("")
      expect(described_class.flatten(nil)).to eq("")
    end
  end
end
