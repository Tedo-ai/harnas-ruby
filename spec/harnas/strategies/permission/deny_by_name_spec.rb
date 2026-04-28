# frozen_string_literal: true

require "harnas/strategies/permission/deny_by_name"
require "harnas/log"
require "harnas/events/tool_use"

RSpec.describe Harnas::Strategies::Permission::DenyByName do
  let(:log) { Harnas::Log.new }

  def tool_use(name)
    log.append(
      type: :tool_use,
      payload: Harnas::Events::ToolUse.new(
        id: "t_#{name}", name: name, arguments: {}
      ).to_h
    )
  end

  it "rejects a non-Array or empty names at construction" do
    expect { described_class.new(names: []) }
      .to raise_error(ArgumentError, /names must be a non-empty Array of Strings/)
    expect { described_class.new(names: "rm") }
      .to raise_error(ArgumentError, /names must be a non-empty Array of Strings/)
  end

  it "denies a tool_use whose name is in the denylist" do
    Harnas::Hooks.scoped do
      described_class.install(names: %w[shell rm])
      decisions = Harnas::Hooks.invoke(:pre_tool_use, tool_use: tool_use("rm"))
      denied = decisions.find { |d| d[:allow] == false }
      expect(denied[:reason]).to match(/"rm" is on the deny-list/)
    end
  end

  it "allows a tool_use whose name is NOT in the denylist" do
    Harnas::Hooks.scoped do
      described_class.install(names: %w[shell rm])
      decisions = Harnas::Hooks.invoke(:pre_tool_use, tool_use: tool_use("echo"))
      expect(decisions).to eq([{ allow: true }])
    end
  end

  it "composes with AlwaysAllow via any-deny-wins" do
    Harnas::Hooks.scoped do
      Harnas::Strategies::Permission::AlwaysAllow.install
      described_class.install(names: %w[rm])
      decisions = Harnas::Hooks.invoke(:pre_tool_use, tool_use: tool_use("rm"))
      denied = decisions.find { |d| d[:allow] == false }
      expect(denied).not_to be_nil
    end
  end

  it "honors a caller-supplied reason_format with $NAME substitution" do
    Harnas::Hooks.scoped do
      described_class.install(names: %w[rm], reason_format: "nope: $NAME")
      decisions = Harnas::Hooks.invoke(:pre_tool_use, tool_use: tool_use("rm"))
      denied = decisions.find { |d| d[:allow] == false }
      expect(denied[:reason]).to eq('nope: "rm"')
    end
  end
end
