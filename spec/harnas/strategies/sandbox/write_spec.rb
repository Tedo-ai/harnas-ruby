# frozen_string_literal: true

require "tmpdir"
require "fileutils"

require "harnas/session"
require "harnas/strategies/sandbox/write"

RSpec.describe Harnas::Strategies::Sandbox::Write do
  def tool_use(path)
    Harnas::Event.new(
      seq: 0,
      id: "evt_tool",
      type: :tool_use,
      payload: { id: "toolu_1", name: "write_file", arguments: { path: path } }
    )
  end

  it "refuses symlink escapes from allowed directories" do
    Dir.mktmpdir do |dir|
      allowed = File.join(dir, "allowed")
      outside = File.join(dir, "outside")
      FileUtils.mkdir_p(allowed)
      FileUtils.mkdir_p(outside)
      File.symlink(outside, File.join(allowed, "escape"))
      session = Harnas::Session.create
      described_class.install(session, allow: [allowed], deny: [])

      decisions = session.hooks.invoke(
        :pre_tool_use,
        session: session,
        tool_use: tool_use(File.join(allowed, "escape", "pwned.txt"))
      )

      expect(decisions.first).to include(allow: false)
      expect(decisions.first[:reason]).to include("pwned.txt")
    end
  end
end
