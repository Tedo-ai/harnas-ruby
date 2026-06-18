# frozen_string_literal: true

require "digest"
require "json"
require "spec_helper"
require "harnas/jcs"

RSpec.describe Harnas::JCS do
  let(:corpus_path) do
    harnas_conformance_oracle("event-content-hash", "vectors.json")
  end
  let(:corpus) { JSON.parse(File.read(corpus_path)) }

  it "matches the harnas-jcs-v1 oracle vectors" do
    corpus.fetch("valid").each do |vector|
      canonical = described_class.canonicalize_json(
        vector.fetch("input_json"),
        exclude_keys: vector.fetch("exclude_keys", [])
      )
      expect(canonical).to eq(vector.fetch("expected_canonical")), vector.fetch("name")
      expect(Digest::SHA256.hexdigest(canonical)).to eq(vector.fetch("expected_content_hash")),
                                                     vector.fetch("name")
    end
  end

  it "fails loudly on invalid unicode" do
    corpus.fetch("invalid").each do |vector|
      expect { described_class.canonicalize_json(vector.fetch("input_json")) }
        .to raise_error(ArgumentError, vector.fetch("expected_error"))
    end
  end

  it "computes Event row content_hash excluding the content_hash field" do
    row = File.read(harnas_conformance_oracle("event-content-hash",
                                              "event-row-with-content-hash.json"))
    expected = File.read(harnas_conformance_oracle("event-content-hash",
                                                   "expected-content-hash.txt")).strip

    expect(described_class.content_hash_json(row)).to eq(expected)
  end
end
