# frozen_string_literal: true

require "harnas/strategies/compaction/tool_output_cap"
require "harnas/session"
require "harnas/events/user_message"
require "harnas/events/assistant_message"
require "harnas/events/tool_use"
require "harnas/events/tool_result"

RSpec.describe Harnas::Strategies::Compaction::ToolOutputCap do
  let(:session) { Harnas::Session.create }

  def append_user(text)
    session.log.append(
      type: :user_message,
      payload: Harnas::Events::UserMessage.new(text: text).to_h
    )
  end

  def append_assistant(text, stop_reason: :end_turn)
    session.log.append(
      type: :assistant_message,
      payload: Harnas::Events::AssistantMessage.new(
        text: text, stop_reason: stop_reason, usage: {}
      ).to_h
    )
  end

  def append_tool_use(id: "call_1", name: "read_file", arguments: {})
    session.log.append(
      type: :tool_use,
      payload: Harnas::Events::ToolUse.new(
        id: id, name: name, arguments: arguments
      ).to_h
    )
  end

  def append_tool_result(tool_use_id: "call_1", output: "")
    session.log.append(
      type: :tool_result,
      payload: Harnas::Events::ToolResult.new(
        tool_use_id: tool_use_id, output: output
      ).to_h
    )
  end

  describe "construction" do
    it "rejects a non-positive max_bytes" do
      expect { described_class.new(max_bytes: 0, prefix_bytes: 0, summary_format: "x") }
        .to raise_error(ArgumentError, /max_bytes/)
    end

    it "rejects prefix_bytes greater than max_bytes" do
      expect { described_class.new(max_bytes: 100, prefix_bytes: 200, summary_format: "x") }
        .to raise_error(ArgumentError, /prefix_bytes/)
    end

    it "rejects a non-String summary_format" do
      expect { described_class.new(max_bytes: 100, prefix_bytes: 10, summary_format: nil) }
        .to raise_error(ArgumentError, /summary_format/)
    end
  end

  describe "#on_pre_projection" do
    it "is a no-op when no :tool_result event exceeds max_bytes" do
      append_user("hi")
      append_assistant("", stop_reason: :tool_use)
      append_tool_use
      append_tool_result(output: "short")

      Harnas::Hooks.scoped do
        described_class.install(max_bytes: 4096, prefix_bytes: 1024)
        Harnas::Hooks.invoke(:pre_projection, session: session)
      end

      expect(session.log.map(&:type)).not_to include(:compact)
    end

    it "emits a :compact replacing the tool pair when the output exceeds max_bytes" do
      append_user("hi")                                                       # 0
      append_assistant("", stop_reason: :tool_use)                            # 1
      append_tool_use(id: "call_1")                                           # 2
      append_tool_result(tool_use_id: "call_1", output: "x" * 5000)           # 3

      Harnas::Hooks.scoped do
        described_class.install(max_bytes: 4096, prefix_bytes: 1024)
        Harnas::Hooks.invoke(:pre_projection, session: session)
      end

      compact = session.log.find { |e| e.type == :compact }
      expect(compact).not_to be_nil
      expect(compact.payload[:replaces]).to eq([2, 3])
    end

    it "includes the tool name, cap, and original size in the summary" do
      append_user("hi")
      append_assistant("", stop_reason: :tool_use)
      append_tool_use(id: "call_1", name: "read_big_file")
      append_tool_result(tool_use_id: "call_1", output: "y" * 10_000)

      Harnas::Hooks.scoped do
        described_class.install(max_bytes: 1024, prefix_bytes: 128)
        Harnas::Hooks.invoke(:pre_projection, session: session)
      end

      compact = session.log.find { |e| e.type == :compact }
      expect(compact.payload[:summary]).to include("read_big_file")
      expect(compact.payload[:summary]).to include("1024")
      expect(compact.payload[:summary]).to include("10000")
    end

    it "preserves the configured prefix of the original output in the summary" do
      distinctive = "HEADLINE-#{"a" * 2000}"
      append_user("hi")
      append_assistant("", stop_reason: :tool_use)
      append_tool_use(id: "call_1")
      append_tool_result(tool_use_id: "call_1", output: distinctive)

      Harnas::Hooks.scoped do
        described_class.install(max_bytes: 1024, prefix_bytes: 64)
        Harnas::Hooks.invoke(:pre_projection, session: session)
      end

      compact = session.log.find { |e| e.type == :compact }
      expect(compact.payload[:summary]).to include("HEADLINE-")
    end

    it "collapses multiple oversized tool pairs with distinct :compact events" do
      append_user("hi")
      append_assistant("", stop_reason: :tool_use)
      append_tool_use(id: "call_1", name: "t1")
      append_tool_result(tool_use_id: "call_1", output: "a" * 5000)
      append_assistant("", stop_reason: :tool_use)
      append_tool_use(id: "call_2", name: "t2")
      append_tool_result(tool_use_id: "call_2", output: "b" * 5000)

      Harnas::Hooks.scoped do
        described_class.install(max_bytes: 4096, prefix_bytes: 256)
        Harnas::Hooks.invoke(:pre_projection, session: session)
      end

      compacts = session.log.select { |e| e.type == :compact }
      expect(compacts.size).to eq(2)
      expect(compacts.map { |c| c.payload[:replaces] }.sort).to eq([[2, 3], [5, 6]])
    end

    it "is idempotent across repeated :pre_projection invocations" do
      append_user("hi")
      append_assistant("", stop_reason: :tool_use)
      append_tool_use(id: "call_1")
      append_tool_result(tool_use_id: "call_1", output: "z" * 5000)

      Harnas::Hooks.scoped do
        described_class.install(max_bytes: 4096, prefix_bytes: 256)
        3.times { Harnas::Hooks.invoke(:pre_projection, session: session) }
      end

      compacts = session.log.select { |e| e.type == :compact }
      expect(compacts.size).to eq(1)
    end

    it "does not split multibyte UTF-8 characters at the prefix boundary" do
      append_user("hi")
      append_assistant("", stop_reason: :tool_use)
      append_tool_use(id: "call_1")
      append_tool_result(tool_use_id: "call_1", output: ("€" * 2000))

      Harnas::Hooks.scoped do
        # "€" is 3 bytes; prefix_bytes = 10 would split the 4th char
        described_class.install(max_bytes: 4096, prefix_bytes: 10)
        Harnas::Hooks.invoke(:pre_projection, session: session)
      end

      compact = session.log.find { |e| e.type == :compact }
      expect(compact.payload[:summary].valid_encoding?).to be(true)
    end

    it "returns a handler that can be removed via Harnas::Hooks.off" do
      handler = described_class.install(max_bytes: 4096, prefix_bytes: 1024)
      expect(Harnas::Hooks.handlers[:pre_projection]).to include(handler)

      Harnas::Hooks.off(:pre_projection, handler)
      expect(Harnas::Hooks.handlers[:pre_projection]).not_to include(handler)
    end
  end

  describe "integration with Projections" do
    it "causes the OpenAI Projection to render the summary in place of the tool pair" do
      require "harnas/projections/openai"

      append_user("give me a file")
      append_assistant("", stop_reason: :tool_use)
      append_tool_use(id: "call_1", name: "read_file")
      append_tool_result(tool_use_id: "call_1", output: "BIGDATA-#{"q" * 5000}")

      Harnas::Hooks.scoped do
        described_class.install(max_bytes: 1024, prefix_bytes: 32)
        Harnas::Hooks.invoke(:pre_projection, session: session)

        projection = Harnas::Projections::OpenAI.new(model: "x")
        result     = projection.call(session.log)

        user_messages = result[:messages].select { |m| m[:role] == "user" }
        expect(user_messages.any? { |m| m[:content].to_s.include?("read_file") }).to be(true)
        expect(user_messages.any? { |m| m[:content].to_s.include?("BIGDATA-") }).to be(true)

        tool_messages = result[:messages].select { |m| m[:role] == "tool" }
        expect(tool_messages).to be_empty
      end
    end
  end
end
