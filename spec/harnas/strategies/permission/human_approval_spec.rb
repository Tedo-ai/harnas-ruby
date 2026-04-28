# frozen_string_literal: true

require "harnas/strategies/permission/human_approval"
require "harnas/log"
require "harnas/events/tool_use"

RSpec.describe Harnas::Strategies::Permission::HumanApproval do
  let(:log) { Harnas::Log.new }
  let(:tool_use) do
    log.append(
      type: :tool_use,
      payload: Harnas::Events::ToolUse.new(
        id: "t1", name: "echo", arguments: { text: "hi" }
      ).to_h
    )
  end

  it "rejects a non-callable prompt at construction" do
    expect { described_class.new(prompt: :not_callable) }
      .to raise_error(ArgumentError, /prompt must respond to #call/)
  end

  it "allows when the prompt callable returns truthy" do
    Harnas::Hooks.scoped do
      described_class.install(prompt: ->(_tu) { true })
      decisions = Harnas::Hooks.invoke(:pre_tool_use, tool_use: tool_use)
      expect(decisions).to eq([{ allow: true }])
    end
  end

  it "denies when the prompt callable returns falsy, with 'human declined' reason" do
    Harnas::Hooks.scoped do
      described_class.install(prompt: ->(_tu) { false })
      decisions = Harnas::Hooks.invoke(:pre_tool_use, tool_use: tool_use)
      denied = decisions.find { |d| d[:allow] == false }
      expect(denied[:reason]).to eq("human declined")
    end
  end

  it "passes the tool_use Event to the prompt callable for inspection" do
    captured = nil
    Harnas::Hooks.scoped do
      described_class.install(prompt: lambda { |tu|
        captured = tu
        true
      })
      Harnas::Hooks.invoke(:pre_tool_use, tool_use: tool_use)
    end
    expect(captured.payload[:name]).to eq("echo")
  end
end
