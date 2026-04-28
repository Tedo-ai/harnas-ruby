# frozen_string_literal: true

require "harnas/strategies/permission/always_allow"
require "harnas/log"
require "harnas/events/tool_use"

RSpec.describe Harnas::Strategies::Permission::AlwaysAllow do
  let(:log) { Harnas::Log.new }
  let(:tool_use) do
    log.append(
      type: :tool_use,
      payload: Harnas::Events::ToolUse.new(
        id: "t1", name: "echo", arguments: { text: "hi" }
      ).to_h
    )
  end

  it "returns an allow decision for any tool_use" do
    Harnas::Hooks.scoped do
      described_class.install
      decisions = Harnas::Hooks.invoke(:pre_tool_use, tool_use: tool_use)
      expect(decisions).to eq([{ allow: true }])
    end
  end
end
