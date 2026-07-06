# frozen_string_literal: true

require "harnas"

RSpec.describe Harnas::Approval do
  let(:session) { Harnas::Session.create }
  let(:registry) do
    registry = Harnas::Tools::Registry.new
    registry.register(
      Harnas::Tools::Tool.new(
        name: "get_current_time",
        description: "time",
        input_schema: { "type" => "object", "properties" => {} }
      ) { |_args| "12:00" }
    )
    registry
  end
  let(:runner) { Harnas::Tools::Runner.new(registry) }

  def append_tool_use(id: "toolu_t1")
    session.log.append(
      type: :tool_use,
      payload: { id: id, name: "get_current_time", arguments: {} }
    )
  end

  describe ".approve" do
    it "appends approval_resolved then executes the tool exactly once" do
      append_tool_use
      described_class.approve(session: session, runner: runner,
                              tool_use_id: "toolu_t1", resolved_by: "tester")

      events = session.log.to_a
      expect(events[-2].type).to eq(:approval_resolved)
      expect(events[-2].payload).to include(decision: "approved", resolved_by: "tester")
      expect(events[-1].type).to eq(:tool_result)
      expect(events[-1].payload[:output]).to eq("12:00")

      expect do
        described_class.approve(session: session, runner: runner, tool_use_id: "toolu_t1")
      end.to raise_error(ArgumentError, /exactly once/)
    end
  end

  describe ".deny" do
    it "appends approval_resolved and the synthesized rejection tool_result" do
      append_tool_use
      described_class.deny(session: session, tool_use_id: "toolu_t1",
                           reason: "operator said no", resolved_by: "tester")

      events = session.log.to_a
      expect(events[-2].payload).to include(decision: "denied", reason: "operator said no")
      expect(events[-1].payload[:error]).to eq("denied by approval: operator said no")
      expect(events[-1].payload[:approval]).to include(
        decision: "rejected", rule_matched: "operator said no"
      )
    end
  end

  it "raises for an unknown tool_use id" do
    expect do
      described_class.approve(session: session, runner: runner, tool_use_id: "missing")
    end.to raise_error(ArgumentError, /no tool_use/)
  end
end
