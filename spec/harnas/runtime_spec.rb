# frozen_string_literal: true

require "harnas/runtime"
require "harnas/conformance/scripted_provider"

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
end
