# frozen_string_literal: true

require "harnas/projections/gemini"
require "harnas/log"
require "harnas/events/user_message"
require "harnas/events/compact"
require "harnas/events/revert"
require "json"

RSpec.describe Harnas::Projections::Gemini do
  let(:projection) { described_class.new(model: "gemini-flash-latest") }
  let(:log)        { Harnas::Log.new }

  it "produces the configured model" do
    log.append(type: :user_message, payload: { text: "hi" })
    expect(projection.call(log)[:model]).to eq("gemini-flash-latest")
  end

  it "uses the `contents` key (not `messages`)" do
    log.append(type: :user_message, payload: { text: "hi" })
    result = projection.call(log)
    expect(result).to have_key(:contents)
    expect(result).not_to have_key(:messages)
  end

  it "wraps user text in role: user, parts: [{ text: ... }]" do
    log.append(type: :user_message, payload: { text: "hello" })
    expect(projection.call(log)[:contents]).to eq([
                                                    { role: "user", parts: [{ text: "hello" }] }
                                                  ])
  end

  it "translates :assistant_message events into role: model (Gemini's convention)" do
    log.append(type: :user_message,      payload: { text: "q" })
    log.append(type: :assistant_message, payload: { text: "a" })
    expect(projection.call(log)[:contents]).to eq([
                                                    { role: "user",  parts: [{ text: "q" }] },
                                                    { role: "model", parts: [{ text: "a" }] }
                                                  ])
  end

  it "preserves event order in the contents array" do
    %w[a b c].each { |t| log.append(type: :user_message, payload: { text: t }) }
    texts = projection.call(log)[:contents].map { |c| c[:parts].first[:text] }
    expect(texts).to eq(%w[a b c])
  end

  it "produces an empty contents array for an empty Log" do
    expect(projection.call(log)[:contents]).to eq([])
  end

  it "ignores unknown event types (forward-compatible)" do
    log.append(type: :user_message, payload: { text: "kept" })
    log.append(type: :some_future_event_type, payload: { whatever: "ignored" })
    expect(projection.call(log)[:contents]).to eq([
                                                    { role: "user", parts: [{ text: "kept" }] }
                                                  ])
  end

  describe "with mutations" do
    it "renders a :compact's summary as a user-role parts entry at the lowest replaced seq" do
      log.append(type: :user_message,      payload: { text: "first" })
      log.append(type: :assistant_message, payload: { text: "second" })
      log.append(
        type: :compact,
        payload: Harnas::Events::Compact.new(replaces: [0, 1], summary: "Earlier turn").to_h
      )
      log.append(type: :user_message, payload: { text: "third" })

      expect(projection.call(log)[:contents]).to eq([
                                                      { role: "user",
                                                        parts: [{ text: "Earlier turn" }] },
                                                      { role: "user", parts: [{ text: "third" }] }
                                                    ])
    end

    it "restores the original contents when a :compact is reverted" do
      log.append(type: :user_message,      payload: { text: "first" })
      log.append(type: :assistant_message, payload: { text: "second" })
      compact = log.append(
        type: :compact,
        payload: Harnas::Events::Compact.new(replaces: [0, 1], summary: "S").to_h
      )
      log.append(type: :revert, payload: Harnas::Events::Revert.new(revokes: compact.seq).to_h)

      expect(projection.call(log)[:contents]).to eq([
                                                      { role: "user", parts: [{ text: "first" }] },
                                                      { role: "model", parts: [{ text: "second" }] }
                                                    ])
    end
  end

  describe "conformance against recorded fixture" do
    let(:fixture_path) do
      File.expand_path(
        "../../../../spec/conformance/fixtures/hello-one-word/gemini/request.json",
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
    let(:projection) { described_class.new(model: "gemini-flash-latest", registry: registry) }

    it "emits tools[] as Gemini functionDeclarations" do
      log.append(type: :user_message, payload: { text: "hi" })
      tools = projection.call(log)[:tools]
      expect(tools).to eq([
                            {
                              functionDeclarations: [{
                                name: "get_current_time",
                                description: "Returns the current UTC time.",
                                parameters: { type: "object", properties: {}, required: [] }
                              }]
                            }
                          ])
    end

    it "emits :tool_use as a functionCall part on a model-role content" do
      log.append(type: :user_message, payload: { text: "hi" })
      log.append(
        type: :tool_use,
        payload: { id: "call_1", name: "get_current_time", arguments: {} }
      )
      contents = projection.call(log)[:contents]
      expect(contents).to eq([
                               { role: "user",  parts: [{ text: "hi" }] },
                               { role: "model", parts: [{
                                 functionCall: { name: "get_current_time", args: {} }
                               }] }
                             ])
    end

    it "emits :tool_result as a functionResponse part on a user-role content" do
      log.append(
        type: :tool_result,
        payload: { tool_use_id: "get_current_time", output: "12:34 UTC" }
      )
      contents = projection.call(log)[:contents]
      expect(contents).to eq([
                               { role: "user", parts: [{
                                 functionResponse: {
                                   name: "get_current_time",
                                   response: { content: "12:34 UTC" }
                                 }
                               }] }
                             ])
    end
  end

  describe "functionResponse name lookup" do
    let(:projection) { described_class.new(model: "gemini-x") }

    it "uses the matching :tool_use's name on the wire even when the id is a synthesized one" do
      log.append(type: :user_message, payload: { text: "hi" })
      log.append(type: :assistant_message, payload: { text: "", stop_reason: :tool_use })
      log.append(
        type: :tool_use,
        payload: { id: "gemini.grep.deadbeef", name: "grep", arguments: { q: "x" } }
      )
      log.append(
        type: :tool_result,
        payload: { tool_use_id: "gemini.grep.deadbeef", output: "match" }
      )

      contents = projection.call(log)[:contents]
      response_part = contents.flat_map { |c| c[:parts] }.find { |p| p[:functionResponse] }
      expect(response_part[:functionResponse][:name]).to eq("grep")
    end

    it "falls back to the tool_use_id when no matching :tool_use is in the Log" do
      log.append(
        type: :tool_result,
        payload: { tool_use_id: "orphan", output: "x" }
      )

      contents = projection.call(log)[:contents]
      response_part = contents.flat_map { |c| c[:parts] }.find { |p| p[:functionResponse] }
      expect(response_part[:functionResponse][:name]).to eq("orphan")
    end
  end

  describe "thoughtSignature round-trip" do
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
    let(:projection) { described_class.new(model: "gemini-x", registry: registry) }

    it "attaches thoughtSignature to a functionCall part when an annotation follows" do
      log.append(type: :user_message, payload: { text: "hi" })
      log.append(type: :assistant_message, payload: { text: "", stop_reason: :tool_use })
      log.append(
        type: :tool_use,
        payload: { id: "get_current_time", name: "get_current_time", arguments: {} }
      )
      log.append(
        type: :annotation,
        payload: { kind: "gemini.thought_signature",
                   data: { name: "get_current_time", signature: "sig-xyz" } }
      )

      contents = projection.call(log)[:contents]
      model_entry = contents.find do |c|
        c[:role] == "model" && c[:parts].any? { |p| p[:functionCall] }
      end
      function_part = model_entry[:parts].find { |p| p[:functionCall] }

      expect(function_part[:thoughtSignature]).to eq("sig-xyz")
    end

    it "omits thoughtSignature when no annotation follows the :tool_use" do
      log.append(type: :user_message, payload: { text: "hi" })
      log.append(type: :assistant_message, payload: { text: "", stop_reason: :tool_use })
      log.append(
        type: :tool_use,
        payload: { id: "get_current_time", name: "get_current_time", arguments: {} }
      )

      contents = projection.call(log)[:contents]
      function_part = contents.flat_map { |c| c[:parts] }.find { |p| p[:functionCall] }

      expect(function_part).not_to have_key(:thoughtSignature)
    end
  end

  describe "thinking budget" do
    it "defaults to thinking_budget: 0 to suppress thoughtSignature requirements" do
      projection = described_class.new(model: "gemini-x")
      log.append(type: :user_message, payload: { text: "hi" })

      expect(projection.call(log)[:generationConfig]).to eq(
        { thinkingConfig: { thinkingBudget: 0 } }
      )
    end

    it "honors a positive thinking_budget when explicitly set" do
      projection = described_class.new(model: "gemini-x", thinking_budget: 4096)
      log.append(type: :user_message, payload: { text: "hi" })

      expect(projection.call(log)[:generationConfig]).to eq(
        { thinkingConfig: { thinkingBudget: 4096 } }
      )
    end

    it "omits :generationConfig entirely when thinking_budget is nil" do
      projection = described_class.new(model: "gemini-x", thinking_budget: nil)
      log.append(type: :user_message, payload: { text: "hi" })

      expect(projection.call(log)).not_to have_key(:generationConfig)
    end
  end

  describe "with a system prompt" do
    it "emits :systemInstruction with parts carrying the prompt text" do
      projection = described_class.new(model: "gemini-x", system: "You are a helpful assistant.")
      log.append(type: :user_message, payload: { text: "hi" })

      expect(projection.call(log)[:systemInstruction]).to eq(
        { parts: [{ text: "You are a helpful assistant." }] }
      )
    end

    it "omits :systemInstruction when the prompt is nil" do
      projection = described_class.new(model: "gemini-x")
      log.append(type: :user_message, payload: { text: "hi" })

      expect(projection.call(log)).not_to have_key(:systemInstruction)
    end

    it "omits :systemInstruction when the prompt is an empty string" do
      projection = described_class.new(model: "gemini-x", system: "")
      log.append(type: :user_message, payload: { text: "hi" })

      expect(projection.call(log)).not_to have_key(:systemInstruction)
    end
  end
end
