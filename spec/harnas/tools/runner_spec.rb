# frozen_string_literal: true

require "harnas/tools/runner"
require "harnas/tools/registry"
require "harnas/tools/tool"
require "harnas/log"
require "harnas/events/tool_use"
require "harnas/observation"

RSpec.describe Harnas::Tools::Runner do
  let(:log)      { Harnas::Log.new }
  let(:registry) { Harnas::Tools::Registry.new }
  let(:runner)   { described_class.new(registry) }

  let(:echo) do
    Harnas::Tools::Tool.new(
      name: "echo", description: "", input_schema: {}
    ) { |args| args[:text].to_s.upcase }
  end

  before { Harnas::Observation.reset! }
  after  { Harnas::Observation.reset! }

  def append_tool_use(id:, name:, arguments:)
    log.append(
      type: :tool_use,
      payload: Harnas::Events::ToolUse.new(id: id, name: name, arguments: arguments).to_h
    )
  end

  describe "successful execution" do
    before { registry.register(echo) }

    it "appends a :tool_result Event carrying the tool's output" do
      tu = append_tool_use(id: "toolu_1", name: "echo", arguments: { text: "hi" })
      runner.run(tu, into_log: log)

      result = log.at(1)
      expect(result.type).to eq(:tool_result)
      expect(result.payload[:tool_use_id]).to eq("toolu_1")
      expect(result.payload[:output]).to eq("HI")
      expect(result.payload[:error]).to be_nil
    end

    it "emits :tool_invoked with outcome :ok and duration_ms" do
      tu = append_tool_use(id: "toolu_1", name: "echo", arguments: { text: "hi" })

      Harnas::Observation.subscribed do |c|
        runner.run(tu, into_log: log)
        e = c.of(:tool_invoked).first[1]
        expect(e[:outcome]).to eq(:ok)
        expect(e[:name]).to eq("echo")
        expect(e[:tool_use_id]).to eq("toolu_1")
        expect(e[:duration_ms]).to be_a(Integer)
      end
    end

    it "passes symbol-keyed arguments by default" do
      seen = nil
      registry.register(
        Harnas::Tools::Tool.new(name: "capture", description: "", input_schema: {}) do |args|
          seen = args
          "ok"
        end
      )
      tu = append_tool_use(id: "toolu_capture", name: "capture", arguments: { "text" => "hi" })

      runner.run(tu, into_log: log)

      expect(seen).to eq({ text: "hi" })
    end

    it "passes string-keyed arguments when the tool requests string style" do
      seen = nil
      registry.register(
        Harnas::Tools::Tool.new(
          name: "capture",
          description: "",
          input_schema: {},
          args_key_style: :string
        ) do |args|
          seen = args
          "ok"
        end
      )
      tu = append_tool_use(id: "toolu_capture", name: "capture", arguments: { text: "hi" })

      runner.run(tu, into_log: log)

      expect(seen).to eq({ "text" => "hi" })
    end
  end

  describe "failed execution" do
    before do
      registry.register(
        Harnas::Tools::Tool.new(name: "boom", description: "", input_schema: {}) do |_|
          raise "kaboom"
        end
      )
    end

    it "appends a :tool_result Event carrying the error message" do
      tu = append_tool_use(id: "toolu_2", name: "boom", arguments: {})
      runner.run(tu, into_log: log)

      result = log.at(1)
      expect(result.type).to eq(:tool_result)
      expect(result.payload[:error]).to match(/RuntimeError: kaboom/)
      expect(result.payload[:output]).to be_nil
    end

    it "emits :tool_invoked with outcome :error and the exception" do
      tu = append_tool_use(id: "toolu_2", name: "boom", arguments: {})

      Harnas::Observation.subscribed do |c|
        runner.run(tu, into_log: log)
        e = c.of(:tool_invoked).first[1]
        expect(e[:outcome]).to eq(:error)
        expect(e[:error]).to be_a(RuntimeError)
      end
    end
  end

  describe "unknown tool" do
    it "records a ToolResult error referencing UnknownToolError" do
      tu = append_tool_use(id: "toolu_3", name: "missing", arguments: {})
      runner.run(tu, into_log: log)

      result = log.at(1)
      expect(result.type).to eq(:tool_result)
      expect(result.payload[:error]).to match(/UnknownToolError/)
    end
  end
end
