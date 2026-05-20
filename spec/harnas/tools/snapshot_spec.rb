# frozen_string_literal: true

require "harnas/tools/snapshot"
require "harnas/tools/registry"
require "harnas/tools/tool"

RSpec.describe Harnas::Tools::Snapshot do
  it "exports registry descriptors with config for metadata snapshots" do
    registry = Harnas::Tools::Registry.new
    registry.register(
      Harnas::Tools::Tool.new(
        name: "load_skill",
        handler: "harnas.builtin.load_skill",
        description: "Load a skill",
        input_schema: { type: "object" },
        config: { skills_dir: "/tmp/skills" }
      ) { "ok" }
    )

    expect(described_class.descriptors(registry)).to eq(
      [
        {
          "name" => "load_skill",
          "handler" => "harnas.builtin.load_skill",
          "description" => "Load a skill",
          "input_schema" => { "type" => "object" },
          "config" => { "skills_dir" => "/tmp/skills" },
          "args_key_style" => "symbol"
        }
      ]
    )
  end
end
