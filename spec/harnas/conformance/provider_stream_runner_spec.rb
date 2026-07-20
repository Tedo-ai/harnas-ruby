# frozen_string_literal: true

require "spec_helper"
require "harnas/conformance/provider_stream_runner"

RSpec.describe Harnas::Conformance::ProviderStreamRunner do
  it "passes the raw provider-stream corpus through the production adapters" do
    corpus = File.join(
      HarnasSpecPaths.spec_root, "conformance", "provider-streams", "corpus.json"
    )
    skip "provider-stream corpus is not present in this spec version" unless File.file?(corpus)

    report = described_class.run(HarnasSpecPaths.spec_root)

    expect(report.cases).to eq(18)
    expect(report.profiles).to eq(39)
  end
end
