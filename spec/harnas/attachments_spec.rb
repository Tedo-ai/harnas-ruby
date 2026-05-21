# frozen_string_literal: true

require "base64"
require "tmpdir"
require "harnas/attachments"
require "harnas/log"

RSpec.describe Harnas::Attachments do
  it "stores filesystem attachments and lists refs from a Log" do
    Dir.mktmpdir("harnas-attachments") do |dir|
      store = described_class::FilesystemStore.new(root: dir)
      ref = store.put("image-bytes", "image/png")

      expect(ref.uri).to start_with("attachment://")
      expect(ref.source).to eq(kind: "ref", uri: ref.uri)
      expect(store.get(ref.uri)).to eq(["image-bytes", "image/png"])

      log = Harnas::Log.new
      log.append(
        type: :user_message,
        payload: {
          content: [
            { type: "image", media_type: "image/png", source: ref.source }
          ]
        }
      )
      expect(store.list_referenced(log)).to eq([ref.uri])

      store.delete(ref.uri)
      expect(store.exists?(ref.uri)).to be(false)
    end
  end

  it "stores memory attachments" do
    store = described_class::MemoryStore.new
    ref = store.put("pdf", "application/pdf")

    expect(store.exists?(ref.uri)).to be(true)
    expect(store.get(ref.uri)).to eq(["pdf", "application/pdf"])
  end

  it "returns inline base64 sources" do
    ref = described_class::InlineStore.new.put("abc", "image/jpeg")

    expect(ref.uri).to be_nil
    expect(ref.source).to eq(
      kind: "base64",
      data: Base64.strict_encode64("abc")
    )
  end
end
