# frozen_string_literal: true

require "harnas/transcript"
require "harnas/log"

RSpec.describe Harnas::Transcript do
  it "projects messages and tool events into UI-neutral items" do
    log = Harnas::Log.new
    log.append(type: :user_message, payload: { text: "hello" })
    log.append(type: :assistant_message,
               payload: { text: "", stop_reason: :tool_use, usage: {} })
    log.append(type: :tool_use,
               payload: { id: "call_1", name: "read_file", arguments: { path: "README.md" } })
    log.append(type: :tool_result,
               payload: { tool_use_id: "call_1", output: "body", error: nil })
    log.append(type: :provider_error,
               payload: { message: "rate limited", terminal: true })

    items = described_class.project(log)

    expect(items.map { |item| item[:kind] })
      .to eq(%w[user assistant tool_use tool_result provider_error])
    expect(items[2]).to include(name: "read_file", tool_use_id: "call_1")
    expect(items[3]).to include(status: "ok", output: "body")
    expect(items[4]).to include(error: "rate limited", terminal: true)
  end

  it "can hide tool detail for compact chat transcripts" do
    log = Harnas::Log.new
    log.append(type: :tool_use, payload: { id: "call_1", name: "grep", arguments: {} })

    expect(described_class.project(log, include_tools: false)).to eq([])
  end
end
