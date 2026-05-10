# frozen_string_literal: true

require "tmpdir"
require "harnas/skills"

RSpec.describe Harnas::Skills do
  describe ".build_index" do
    it "builds the canonical skills prompt section" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "git_workflow.md"), <<~MD)
          ---
          name: git_workflow
          description: Branching, commit, and PR description conventions
          triggers: [pr, commit]
          category: coding
          ---
          Body
        MD

        expect(described_class.build_index(dir)).to eq(<<~TEXT.chomp)
          ## Skills

          You have access to local skills. The skill index below is enough to answer what skills are available. Do not call `load_skill` just to list skills. Call `load_skill` only when a user request matches a skill and you need its full instructions.

          - `git_workflow`: Branching, commit, and PR description conventions Category: coding. Triggers: pr, commit.
        TEXT
      end
    end

    it "returns an empty string for an empty directory" do
      Dir.mktmpdir do |dir|
        expect(described_class.build_index(dir)).to eq("")
      end
    end
  end
end
