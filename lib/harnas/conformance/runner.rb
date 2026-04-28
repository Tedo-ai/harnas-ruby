# frozen_string_literal: true

require "json"
require "harnas/manifest"
require "harnas/tools/runner"
require "harnas/agent_loop"
require "harnas/events/user_message"
require "harnas/hooks"
require "harnas/conformance/scripted_provider"

module Harnas
  module Conformance
    # Runs an agent-level conformance fixture.
    #
    # A fixture is a directory with these files:
    #
    #   manifest.json         — a standard spec/18 Agent Manifest
    #   provider-script.json  — an ordered array of provider responses
    #                           (wire-shape matching the manifest's
    #                           provider kind)
    #   inputs.json           — an array of user message strings
    #   expected-log.jsonl    — the Log any conformant implementation
    #                           must produce: one JSON event per line,
    #                           with seq / type / payload fields
    #
    # The runner:
    #
    #   1. Loads the manifest with placeholder api_keys / handlers.
    #   2. Replaces the manifest's provider with a ScriptedProvider
    #      that serves the recorded responses one-per-call.
    #   3. Installs the manifest's strategies in a scoped Hooks context.
    #   4. Appends each input as a :user_message and runs the AgentLoop
    #      against the scripted provider.
    #   5. Serializes the resulting Log and diffs it against
    #      expected-log.jsonl.
    #
    # Any spec-conformant Harnas implementation in any language,
    # fed the same manifest + script + inputs, MUST produce the same
    # serialized Log.
    module Runner
      Result = Data.define(:fixture, :passed, :diff, :actual, :expected) do
        def summary
          return "#{fixture}  ok (#{actual.size} events)" if passed

          "#{fixture}  FAIL at seq #{diff[:at_seq]}"
        end
      end

      def self.run(dir)
        manifest  = JSON.parse(File.read(File.join(dir, "manifest.json")))
        responses = JSON.parse(File.read(File.join(dir, "provider-script.json")))
        inputs    = JSON.parse(File.read(File.join(dir, "inputs.json")))
        expected  = load_expected(File.join(dir, "expected-log.jsonl"))

        actual = run_agent(manifest, responses, inputs)

        diff = first_mismatch(actual, expected)
        Result.new(
          fixture: File.basename(dir),
          passed: diff.nil?,
          diff: diff,
          actual: actual,
          expected: expected
        )
      end

      def self.run_agent(manifest, responses, inputs)
        scripted = ScriptedProvider.new(responses: responses)
        loaded   = Harnas::Manifest.load(
          manifest,
          api_keys: conformance_api_keys,
          tool_handlers: conformance_tool_handlers,
          strategy_handlers: conformance_strategy_handlers
        )

        Harnas::Hooks.scoped do
          loaded.install_strategies!
          drive_inputs(loaded, scripted, inputs)
        end

        serialize_log(loaded.session.log)
      end

      def self.drive_inputs(loaded, scripted, inputs)
        inputs.each do |text|
          loaded.session.log.append(
            type: :user_message,
            payload: Harnas::Events::UserMessage.new(text: text).to_h
          )
          Harnas::AgentLoop.new(
            session: loaded.session,
            projection: loaded.projection,
            runner: loaded.runner,
            provider: scripted,
            ingestor: loaded.ingestor,
            max_turns: 3
          ).run
        end
      end

      # Generous defaults so fixtures can reference any kind / tool /
      # handler without the runner failing on missing keys. Real provider
      # calls are replaced by ScriptedProvider; these values are never
      # used on the wire.
      def self.conformance_api_keys
        { anthropic: "conformance-fixture-key",
          openai: "conformance-fixture-key",
          gemini: "conformance-fixture-key" }
      end

      # Any tool handler name resolves to a stub that echoes its
      # arguments in the normative format defined by
      # spec/conformance/README.md (compact JSON for the args). Fixtures
      # whose agent loop invokes tools get deterministic, language-
      # neutral output.
      def self.conformance_tool_handlers
        Hash.new do |_, name|
          ->(args) { "[conformance stub: #{name}(#{JSON.generate(args)})]" }
        end
      end

      # Any strategy handler (e.g. HumanApproval prompts) resolves to
      # "always allow" so human-gated strategies run deterministically.
      def self.conformance_strategy_handlers
        Hash.new { |_, _| ->(_tool_use) { true } }
      end

      def self.load_expected(path)
        File.read(path).each_line.reject(&:empty?).map { |line| normalize(JSON.parse(line)) }
      end

      def self.serialize_log(log)
        log.map do |event|
          normalize(
            "seq" => event.seq,
            "type" => event.type.to_s,
            "payload" => event.payload
          )
        end
      end

      def self.normalize(value)
        case value
        when Hash   then value.each_with_object({}) { |(k, v), h| h[k.to_s] = normalize(v) }
        when Array  then value.map { |v| normalize(v) }
        when Symbol then value.to_s
        else value
        end
      end

      def self.first_mismatch(actual, expected)
        upper = [actual.size, expected.size].max
        upper.times do |i|
          next if actual[i] == expected[i]

          return {
            at_seq: i,
            actual: actual[i],
            expected: expected[i]
          }
        end
        nil
      end
    end
  end
end
