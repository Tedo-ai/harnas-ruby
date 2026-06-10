# frozen_string_literal: true

require "harnas/session"
require "harnas/strategies/sandbox/network"

RSpec.describe Harnas::Strategies::Sandbox::Network do
  def tool_use(url)
    Harnas::Event.new(
      seq: 0,
      id: "evt_tool",
      type: :tool_use,
      payload: { id: "toolu_1", name: "fetch_url", arguments: { url: url } }
    )
  end

  it "allows configured hosts and refuses others" do
    session = Harnas::Session.create
    described_class.install(session, allow: ["api.github.com"], deny: [])

    allowed = session.hooks.invoke(
      :pre_tool_use,
      session: session,
      tool_use: tool_use("https://api.github.com/repos/foo")
    )
    denied = session.hooks.invoke(
      :pre_tool_use,
      session: session,
      tool_use: tool_use("https://evil.example.com/")
    )

    expect(allowed).to eq([{ allow: true }])
    expect(denied.first).to include(allow: false)
    expect(denied.first[:reason]).to include("evil.example.com")
  end

  it "refuses unparseable URLs instead of failing open" do
    session = Harnas::Session.create
    described_class.install(session, allow: ["api.github.com"], deny: [])

    decisions = session.hooks.invoke(
      :pre_tool_use,
      session: session,
      tool_use: tool_use("http://[::1")
    )

    expect(decisions.first).to include(allow: false)
    expect(decisions.first[:reason]).to include("unparseable URL")
  end
end
