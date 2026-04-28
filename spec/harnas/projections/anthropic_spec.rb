# frozen_string_literal: true

require "harnas/projections/anthropic"
require "harnas/log"
require "harnas/events/user_message"
require "harnas/events/compact"
require "harnas/events/revert"
require "harnas/events/tool_use"
require "harnas/events/tool_result"
require "harnas/tools/registry"
require "harnas/tools/tool"
require "json"

RSpec.describe Harnas::Projections::Anthropic do
  let(:projection) { described_class.new(model: "claude-sonnet-4-5") }
  let(:log)        { Harnas::Log.new }

  it "produces the configured model and default max_tokens" do
    log.append(type: :user_message, payload: { text: "hi" })
    result = projection.call(log)
    expect(result[:model]).to eq("claude-sonnet-4-5")
    expect(result[:max_tokens]).to eq(1024)
  end

  it "honors an explicit max_tokens" do
    p = described_class.new(model: "x", max_tokens: 4000)
    expect(p.call(log)[:max_tokens]).to eq(4000)
  end

  it "translates :user_message events into role: user, content: text" do
    log.append(type: :user_message, payload: { text: "hello" })
    expect(projection.call(log)[:messages]).to eq([{ role: "user", content: "hello" }])
  end

  it "translates :assistant_message events into role: assistant" do
    log.append(type: :user_message, payload: { text: "q" })
    log.append(type: :assistant_message, payload: { text: "a" })
    expect(projection.call(log)[:messages]).to eq([
                                                    { role: "user", content: "q" },
                                                    { role: "assistant", content: "a" }
                                                  ])
  end

  it "preserves event order across role changes" do
    log.append(type: :user_message,      payload: { text: "a" })
    log.append(type: :assistant_message, payload: { text: "b" })
    log.append(type: :user_message,      payload: { text: "c" })
    expect(projection.call(log)[:messages].map { |m| m[:content] }).to eq(%w[a b c])
  end

  it "coalesces adjacent same-role events into one wire message with a content array" do
    %w[a b c].each { |t| log.append(type: :user_message, payload: { text: t }) }
    messages = projection.call(log)[:messages]
    expect(messages.size).to eq(1)
    expect(messages.first[:content]).to eq([
                                             { type: "text", text: "a" },
                                             { type: "text", text: "b" },
                                             { type: "text", text: "c" }
                                           ])
  end

  it "produces an empty messages array for an empty Log" do
    expect(projection.call(log)[:messages]).to eq([])
  end

  it "ignores unknown event types (forward-compatible)" do
    log.append(type: :user_message,  payload: { text: "kept" })
    log.append(type: :unknown_event, payload: { foo: "bar" })
    expect(projection.call(log)[:messages]).to eq([{ role: "user", content: "kept" }])
  end

  describe "with mutations" do
    it "renders a :compact's summary as a user message at the lowest replaced seq" do
      log.append(type: :user_message,      payload: { text: "first" })
      log.append(type: :assistant_message, payload: { text: "second" })
      log.append(
        type: :compact,
        payload: Harnas::Events::Compact.new(replaces: [0, 1], summary: "Earlier turn").to_h
      )
      log.append(type: :user_message, payload: { text: "third" })

      # After mutation: summary (user) + "third" (user) coalesce into one
      # user message with a content array of two text blocks.
      expect(projection.call(log)[:messages]).to eq([
                                                      { role: "user", content: [
                                                        { type: "text", text: "Earlier turn" },
                                                        { type: "text", text: "third" }
                                                      ] }
                                                    ])
    end

    it "restores the original messages when a :compact is reverted" do
      log.append(type: :user_message,      payload: { text: "first" })
      log.append(type: :assistant_message, payload: { text: "second" })
      compact = log.append(
        type: :compact,
        payload: Harnas::Events::Compact.new(replaces: [0, 1], summary: "S").to_h
      )
      log.append(type: :revert, payload: Harnas::Events::Revert.new(revokes: compact.seq).to_h)

      expect(projection.call(log)[:messages]).to eq([
                                                      { role: "user", content: "first" },
                                                      { role: "assistant", content: "second" }
                                                    ])
    end
  end

  describe "with tools registered" do
    let(:registry) do
      r = Harnas::Tools::Registry.new
      r.register(Harnas::Tools::Tool.new(
        name: "echo",
        description: "Echoes its text argument back.",
        input_schema: { type: "object", properties: { text: { type: "string" } } }
      ) { |args| args[:text].to_s })
      r
    end

    let(:projection_with_tools) do
      described_class.new(model: "claude-sonnet-4-5", registry: registry)
    end

    it "emits a top-level tools array when the registry has any tools" do
      result = projection_with_tools.call(log)
      expect(result[:tools]).to eq([{
                                     name: "echo",
                                     description: "Echoes its text argument back.",
                                     input_schema: {
                                       type: "object",
                                       properties: { text: { type: "string" } }
                                     }
                                   }])
    end

    it "does not emit tools when the registry is nil or empty" do
      expect(projection.call(log)).not_to have_key(:tools)
      empty = described_class.new(model: "x", registry: Harnas::Tools::Registry.new)
      expect(empty.call(log)).not_to have_key(:tools)
    end
  end

  describe "with tool_use and tool_result events" do
    it "groups :assistant_message + :tool_use into one assistant message with a content array" do
      log.append(type: :user_message, payload: { text: "use echo with hi" })
      log.append(type: :assistant_message,
                 payload: { text: "I will.", stop_reason: :tool_use, usage: {} })
      log.append(
        type: :tool_use,
        payload: Harnas::Events::ToolUse.new(id: "toolu_1", name: "echo",
                                             arguments: { text: "hi" }).to_h
      )

      messages = projection.call(log)[:messages]
      expect(messages.size).to eq(2)
      expect(messages[1][:role]).to eq("assistant")
      expect(messages[1][:content]).to eq([
                                            { type: "text", text: "I will." },
                                            { type: "tool_use", id: "toolu_1", name: "echo",
                                              input: { text: "hi" } }
                                          ])
    end

    it "renders :tool_result as a user message with a tool_result content block" do
      log.append(
        type: :tool_result,
        payload: Harnas::Events::ToolResult.new(tool_use_id: "toolu_1", output: "hi").to_h
      )

      result = projection.call(log)[:messages].first
      expect(result[:role]).to eq("user")
      expect(result[:content]).to eq([
                                       { type: "tool_result", tool_use_id: "toolu_1",
                                         content: "hi" }
                                     ])
    end

    it "marks a :tool_result with :error as is_error: true" do
      log.append(
        type: :tool_result,
        payload: Harnas::Events::ToolResult.new(tool_use_id: "toolu_2", error: "oops").to_h
      )

      block = projection.call(log)[:messages].first[:content].first
      expect(block[:content]).to eq("oops")
      expect(block[:is_error]).to be(true)
    end

    it "skips an :assistant_message with empty text" do
      log.append(type: :assistant_message, payload: { text: "", stop_reason: :tool_use, usage: {} })
      log.append(
        type: :tool_use,
        payload: Harnas::Events::ToolUse.new(id: "toolu_1", name: "echo", arguments: {}).to_h
      )

      messages = projection.call(log)[:messages]
      expect(messages.size).to eq(1)
      expect(messages.first[:content]).to eq([
                                               { type: "tool_use", id: "toolu_1", name: "echo",
                                                 input: {} }
                                             ])
    end
  end

  describe "conformance against recorded fixture" do
    let(:fixture_path) do
      File.expand_path(
        "../../../../spec/conformance/fixtures/hello-one-word/anthropic/request.json",
        __dir__
      )
    end

    it "produces exactly the recorded request body for the canonical Log" do
      log.append(
        type: :user_message,
        payload: Harnas::Events::UserMessage.new(text: "say hello in one word").to_h
      )

      result   = projection.call(log)
      expected = JSON.parse(File.read(fixture_path), symbolize_names: true)

      expect(result).to eq(expected)
    end
  end

  describe "with a system prompt" do
    it "emits the system prompt as a top-level :system field" do
      projection = described_class.new(model: "claude-x", system: "You are a helpful assistant.")
      log.append(type: :user_message, payload: { text: "hi" })

      expect(projection.call(log)[:system]).to eq("You are a helpful assistant.")
    end

    it "omits :system when the prompt is nil" do
      projection = described_class.new(model: "claude-x")
      log.append(type: :user_message, payload: { text: "hi" })

      expect(projection.call(log)).not_to have_key(:system)
    end

    it "omits :system when the prompt is an empty string" do
      projection = described_class.new(model: "claude-x", system: "")
      log.append(type: :user_message, payload: { text: "hi" })

      expect(projection.call(log)).not_to have_key(:system)
    end
  end
end
