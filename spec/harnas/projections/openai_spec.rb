# frozen_string_literal: true

require "harnas/projections/openai"
require "harnas/log"
require "harnas/events/user_message"
require "harnas/events/compact"
require "harnas/events/revert"
require "json"

RSpec.describe Harnas::Projections::OpenAI do
  let(:projection) { described_class.new(model: "gpt-5.4-mini") }
  let(:log)        { Harnas::Log.new }

  it "produces the configured model" do
    log.append(type: :user_message, payload: { text: "hi" })
    expect(projection.call(log)[:model]).to eq("gpt-5.4-mini")
  end

  it "does not add max_tokens (OpenAI does not require it)" do
    log.append(type: :user_message, payload: { text: "hi" })
    expect(projection.call(log)).not_to have_key(:max_tokens)
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

  it "preserves event order in the messages array" do
    %w[a b c].each { |t| log.append(type: :user_message, payload: { text: t }) }
    expect(projection.call(log)[:messages].map { |m| m[:content] }).to eq(%w[a b c])
  end

  it "produces an empty messages array for an empty Log" do
    expect(projection.call(log)[:messages]).to eq([])
  end

  it "ignores unknown event types (forward-compatible)" do
    log.append(type: :user_message, payload: { text: "kept" })
    log.append(type: :some_future_event_type, payload: { whatever: "ignored" })
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

      expect(projection.call(log)[:messages]).to eq([
                                                      { role: "user", content: "Earlier turn" },
                                                      { role: "user", content: "third" }
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

  describe "conformance against recorded fixture" do
    let(:fixture_path) do
      harnas_conformance_fixture("hello-one-word", "openai", "request.json")
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

  describe "with a tool Registry" do
    let(:registry) do
      require "harnas/tools/registry"
      require "harnas/tools/tool"
      reg = Harnas::Tools::Registry.new
      reg.register(
        Harnas::Tools::Tool.new(
          name: "get_current_time",
          description: "Returns the current UTC time.",
          input_schema: { type: "object", properties: {}, required: [] }
        ) { |_| Time.now.utc.iso8601 }
      )
      reg
    end
    let(:projection) { described_class.new(model: "gpt-5.4-mini", registry: registry) }

    it "emits tools[] as OpenAI function declarations" do
      log.append(type: :user_message, payload: { text: "hi" })
      tools = projection.call(log)[:tools]
      expect(tools).to eq([
                            {
                              type: "function",
                              function: {
                                name: "get_current_time",
                                description: "Returns the current UTC time.",
                                parameters: { type: "object", properties: {}, required: [] }
                              }
                            }
                          ])
    end

    it "folds a :tool_use into the preceding assistant message's tool_calls" do
      log.append(type: :user_message,      payload: { text: "hi" })
      log.append(type: :assistant_message, payload: { text: "", stop_reason: :tool_use })
      log.append(
        type: :tool_use,
        payload: { id: "call_1", name: "get_current_time", arguments: {} }
      )

      messages = projection.call(log)[:messages]
      expect(messages).to eq([
                               { role: "user", content: "hi" },
                               {
                                 role: "assistant", content: nil,
                                 tool_calls: [{
                                   id: "call_1",
                                   type: "function",
                                   function: { name: "get_current_time", arguments: "{}" }
                                 }]
                               }
                             ])
    end

    it "emits :tool_result as a role: tool message" do
      log.append(
        type: :tool_result,
        payload: { tool_use_id: "call_1", output: "12:34 UTC" }
      )
      messages = projection.call(log)[:messages]
      expect(messages).to eq([
                               { role: "tool", tool_call_id: "call_1", content: "12:34 UTC" }
                             ])
    end
  end

  describe "with a system prompt" do
    it "prepends a role: 'system' message when a prompt is set" do
      projection = described_class.new(model: "gpt-x", system: "You are a helpful assistant.")
      log.append(type: :user_message, payload: { text: "hi" })

      messages = projection.call(log)[:messages]
      expect(messages.first).to eq({ role: "system", content: "You are a helpful assistant." })
    end

    it "does not add a system message when the prompt is nil" do
      projection = described_class.new(model: "gpt-x")
      log.append(type: :user_message, payload: { text: "hi" })

      messages = projection.call(log)[:messages]
      expect(messages.map { |m| m[:role] }).not_to include("system")
    end

    it "does not add a system message when the prompt is an empty string" do
      projection = described_class.new(model: "gpt-x", system: "")
      log.append(type: :user_message, payload: { text: "hi" })

      messages = projection.call(log)[:messages]
      expect(messages.map { |m| m[:role] }).not_to include("system")
    end
  end
end
