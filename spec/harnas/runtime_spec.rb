# frozen_string_literal: true

require "harnas/runtime"
require "harnas/conformance/scripted_provider"
require "harnas/events/tool_use"
require "harnas/tools/tool"

RSpec.describe Harnas::Runtime do
  let(:manifest) do
    {
      "harnas_version" => "0.1",
      "name" => "runtime-test",
      "provider" => { "kind" => "mock", "model" => "mock-test", "max_tokens" => 128 },
      "tools" => [],
      "strategies" => []
    }
  end

  it "builds an agent from a manifest and metadata" do
    runtime = described_class.build(manifest: manifest, metadata: { "trace_id" => "tr_1" })
    runtime.loaded.instance_variable_set(
      :@provider,
      Harnas::Conformance::ScriptedProvider.new(
        responses: [{ "content" => [{ "type" => "text", "text" => "ok" }],
                      "stop_reason" => "end_turn", "usage" => {} }]
      )
    )

    response = runtime.agent.chat("hi")

    expect(response.text).to eq("ok")
    expect(runtime.session.metadata).to include("trace_id" => "tr_1")
  end

  it "resumes a saved session when requested" do
    session = Harnas::Session.create
    session.log.append(type: :user_message, payload: { text: "old" })

    Dir.mktmpdir do |dir|
      path = File.join(dir, "session.jsonl")
      session.save(path)

      runtime = described_class.build(manifest: manifest, session_path: path, resume: true)

      expect(runtime.session.id).to eq(session.id)
      expect(runtime.session.log.map { |event| event.payload[:text] }).to eq(["old"])
    end
  end

  it "raises a clear error when a Tool instance is passed instead of a Hash descriptor" do
    tool = Harnas::Tools::Tool.new(
      name: "bad",
      description: "bad",
      input_schema: {}
    ) { "bad" }
    bad_manifest = manifest.merge("tools" => [tool])

    expect { described_class.build(manifest: bad_manifest) }
      .to raise_error(ArgumentError, /Hash descriptors.*tool_handlers/)
  end

  it "uses string-keyed tool arguments when args_key_style is set globally" do
    runtime = described_class.build(
      manifest: manifest.merge(
        "tools" => [{
          "name" => "capture",
          "handler" => "test.capture",
          "description" => "Capture arguments",
          "input_schema" => {}
        }]
      ),
      tool_handlers: { "test.capture" => ->(_args) { "ok" } },
      args_key_style: :string
    )

    expect(runtime.registry["capture"].args_key_style).to eq(:string)
  end

  it "lets per-tool args_key_style override the global setting" do
    runtime = described_class.build(
      manifest: manifest.merge(
        "tools" => [{
          "name" => "capture",
          "handler" => "test.capture",
          "description" => "Capture arguments",
          "input_schema" => {},
          "args_key_style" => "symbol"
        }]
      ),
      tool_handlers: { "test.capture" => ->(_args) { "ok" } },
      args_key_style: :string
    )

    expect(runtime.registry["capture"].args_key_style).to eq(:symbol)
  end

  it "passes string keys through MCP-style tool handlers with args_key_style string" do
    seen = nil
    runtime = described_class.build(
      manifest: manifest.merge(
        "tools" => [{
          "name" => "editorial-ai.fetch_story",
          "handler" => "mcp_passthrough.editorial-ai",
          "description" => "Fetch a story",
          "input_schema" => {},
          "config" => { "mcp_tool_name" => "fetch_story" }
        }]
      ),
      tool_handlers: {
        "mcp_passthrough.editorial-ai" => lambda do |args, config:|
          seen = { args: args, config: config }
          "story"
        end
      },
      args_key_style: :string
    )
    tool_use = runtime.session.log.append(
      type: :tool_use,
      payload: Harnas::Events::ToolUse.new(
        id: "call_1",
        name: "editorial-ai.fetch_story",
        arguments: { uid: "abc" }
      ).to_h
    )

    runtime.runner.run(tool_use, into_log: runtime.session.log)

    expect(seen).to eq(
      args: { "uid" => "abc" },
      config: { "mcp_tool_name" => "fetch_story" }
    )
  end
end
