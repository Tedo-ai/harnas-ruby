# frozen_string_literal: true

require "harnas/projection"
require "harnas/session"

RSpec.describe Harnas::Projection do
  let(:parent) do
    session = Harnas::Session.new(id: "ses_parent")
    spawn = session.log.append(
      type: :agent_spawn,
      payload: { spawn_id: "spn_1", child_session_id: "ses_child", task: "audit" }
    )
    session.log.append(
      type: :agent_status,
      payload: { spawn_id: "spn_1", child_session_id: "ses_child", status: "running" }
    )
    session.log.append(
      type: :agent_result,
      payload: {
        spawn_id: "spn_1",
        child_session_id: "ses_child",
        status: "succeeded",
        result: { text: "done" },
        usage: { prompt_tokens: 1, completion_tokens: 2, total_tokens: 3 }
      }
    )
    [session, spawn]
  end

  let(:child) do
    session = Harnas::Session.new(
      id: "ses_child",
      parent_session_id: "ses_parent",
      root_session_id: "ses_parent",
      spawn_id: "spn_1",
      spawned_by_event_id: parent.last.id,
      delegation_chain: [{ session_id: "ses_parent", spawn_id: nil }]
    )
    session.log.append(
      type: :assistant_message,
      payload: {
        text: "child done",
        stop_reason: :end_turn,
        usage: { input_tokens: 4, output_tokens: 5 }
      }
    )
    session
  end

  let(:runtime) { { "ses_parent" => parent.first, "ses_child" => child } }

  it "projects a delegation tree" do
    tree = described_class.delegation_tree("ses_parent", runtime: runtime)

    expect(tree["children"].first).to include(
      "spawn_id" => "spn_1",
      "status" => "succeeded",
      "result" => { text: "done" }
    )
  end

  it "reports open children" do
    expect(described_class.open_children("ses_parent", runtime: runtime)).to eq([])
  end

  it "aggregates descendant usage" do
    expect(described_class.descendant_usage("ses_parent", runtime: runtime))
      .to eq("prompt_tokens" => 5, "completion_tokens" => 7, "total_tokens" => 12)
  end

  it "rejects broken child links" do
    broken = Harnas::Session.new(
      id: "ses_child",
      parent_session_id: "ses_other",
      spawn_id: "spn_1"
    )

    expect do
      described_class.delegation_tree(
        "ses_parent",
        runtime: { "ses_parent" => parent.first, "ses_child" => broken }
      )
    end.to raise_error(ArgumentError, /broken delegation link/)
  end

  it "rejects duplicate results for one spawn" do
    duplicated = Harnas::Session.new(id: "ses_parent")
    spawn = duplicated.log.append(
      type: :agent_spawn,
      payload: { spawn_id: "spn_1", child_session_id: "ses_child", task: "audit" }
    )
    duplicated.log.append(type: :agent_result,
                          payload: { spawn_id: "spn_1", child_session_id: "ses_child" })
    duplicated.log.append(type: :agent_result,
                          payload: { spawn_id: "spn_1", child_session_id: "ses_child" })
    linked_child = Harnas::Session.new(
      id: "ses_child",
      parent_session_id: "ses_parent",
      spawn_id: "spn_1",
      spawned_by_event_id: spawn.id
    )

    expect do
      described_class.delegation_tree(
        "ses_parent",
        runtime: { "ses_parent" => duplicated, "ses_child" => linked_child }
      )
    end.to raise_error(ArgumentError, /multiple agent_result/)
  end

  it "rejects delegation cycles" do
    a = Harnas::Session.new(id: "ses_a", parent_session_id: "ses_b", spawn_id: "spn_b")
    b = Harnas::Session.new(id: "ses_b", parent_session_id: "ses_a", spawn_id: "spn_a")
    a.log.append(type: :agent_spawn,
                 payload: { spawn_id: "spn_a", child_session_id: "ses_b", task: "b" })
    b.log.append(type: :agent_spawn,
                 payload: { spawn_id: "spn_b", child_session_id: "ses_a", task: "a" })

    expect do
      described_class.delegation_tree("ses_a", runtime: { "ses_a" => a, "ses_b" => b })
    end.to raise_error(ArgumentError, /delegation cycle/)
  end
end
