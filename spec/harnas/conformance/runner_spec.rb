# frozen_string_literal: true

require "harnas/conformance/runner"

RSpec.describe Harnas::Conformance::Runner do
  fixtures_dir = HarnasSpecPaths.conformance_agents

  # Discover every fixture directory at load time so each shows up as
  # its own example. A regression in any one produces a targeted
  # failure with the exact seq / actual / expected that diverged.
  fixture_names = Dir.children(fixtures_dir)
                     .select { |name| File.directory?(File.join(fixtures_dir, name)) }
                     .sort

  fixture_names.each do |fixture_name|
    it "passes the '#{fixture_name}' agent-level fixture" do
      result = described_class.run(File.join(fixtures_dir, fixture_name))
      unless result.passed
        detail = "at seq #{result.diff[:at_seq]}\n  " \
                 "expected: #{result.diff[:expected].inspect}\n  " \
                 "actual:   #{result.diff[:actual].inspect}"
        raise detail
      end
    end
  end

  it "rejects oracle logs with extra actual payload fields" do
    oracle_dir = HarnasSpecPaths.conformance_oracle("strict-diff-extra-payload-field")
    actual = described_class.load_expected(File.join(oracle_dir, "actual-log.jsonl"))
    expected = described_class.load_expected(File.join(oracle_dir, "expected-log.jsonl"))

    expect(described_class.first_mismatch(actual, expected)).not_to be_nil
  end
end
