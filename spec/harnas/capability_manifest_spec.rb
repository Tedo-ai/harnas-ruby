# frozen_string_literal: true

require "harnas/capability_manifest"

RSpec.describe Harnas::CapabilityManifest do
  it "hashes manifests with stable key ordering" do
    a = { tools: ["read_file"], provider: { kind: "mock" } }
    b = { "provider" => { "kind" => "mock" }, "tools" => ["read_file"] }

    expect(described_class.ref(a)).to eq(described_class.ref(b))
    expect(described_class.ref(a)).to start_with("cap_sha256_")
  end

  it "stores manifests in memory by ref" do
    store = described_class::MemoryStore.new
    manifest = { tools: ["read_file"] }
    ref = store.put(manifest)

    expect(store.get(ref)).to eq(manifest)
  end
end
