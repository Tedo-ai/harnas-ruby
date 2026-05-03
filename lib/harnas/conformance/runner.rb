# frozen_string_literal: true

require "json"
require "tmpdir"
require "harnas/manifest"
require "harnas/tools/runner"
require "harnas/agent_loop"
require "harnas/events/user_message"
require "harnas/hooks"
require "harnas/conformance/scripted_provider"
require "harnas/conformance/scripted_stream_provider"

module Harnas
  module Conformance
    # Runs an agent-level conformance fixture.
    #
    # A fixture is a directory with these files:
    #
    #   manifest.json         — a standard spec/18 Agent Manifest
    #   provider-script.json  — an ordered array of buffered provider
    #                           responses (wire-shape matching the
    #                           manifest's provider kind)
    #   provider-script-stream.json
    #                         — for streaming fixtures, an ordered array
    #                           of provider-call streams; each stream is
    #                           an ordered array of Event-args Hashes
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
        manifest = JSON.parse(File.read(File.join(dir, "manifest.json")))
        script, streaming = load_provider_script(dir)
        inputs   = JSON.parse(File.read(File.join(dir, "inputs.json")))
        expected = load_expected(File.join(dir, "expected-log.jsonl"))
        expected_deltas_path = File.join(dir, "expected-deltas.jsonl")

        actual, actual_deltas = run_agent_with_optional_deltas(
          manifest, script, inputs, streaming: streaming,
                                    expected_deltas_path: expected_deltas_path
        )

        diff = first_mismatch(actual, expected)
        if diff.nil? && File.exist?(expected_deltas_path)
          diff = first_mismatch(actual_deltas, load_expected(expected_deltas_path))
        end
        Result.new(
          fixture: File.basename(dir),
          passed: diff.nil?,
          diff: diff,
          actual: actual,
          expected: expected
        )
      end

      def self.run_agent(manifest, script, inputs, streaming: false)
        serialize_log(run_session(manifest, script, inputs, streaming: streaming).log)
      end

      def self.run_agent_with_optional_deltas(manifest, script, inputs, streaming: false,
                                              expected_deltas_path: nil)
        return [run_agent(manifest, script, inputs, streaming: streaming), []] \
          unless expected_deltas_path && File.exist?(expected_deltas_path)

        Dir.mktmpdir("harnas-deltas") do |dir|
          delta_path = File.join(dir, "session.deltas.jsonl")
          session = run_session(manifest, script, inputs, streaming: streaming,
                                                          delta_path: delta_path)
          [serialize_log(session.log), load_expected(delta_path)]
        end
      end

      def self.run_session(manifest, script, inputs, streaming: false, session: nil,
                           delta_path: nil)
        scripted = if streaming
                     ScriptedStreamProvider.new(streams: script)
                   else
                     ScriptedProvider.new(responses: script)
                   end
        loaded   = Harnas::Manifest.load(
          manifest,
          api_keys: conformance_api_keys,
          tool_handlers: conformance_tool_handlers,
          strategy_handlers: conformance_strategy_handlers
        )
        loaded = loaded.with_session(session) if session
        if delta_path
          Harnas::Observation::DeltaLogger.new(
            path: delta_path,
            observation: loaded.session.observation
          )
        end

        Harnas::Hooks.scoped do
          loaded.install_strategies!
          loaded = drive_inputs(loaded, scripted, inputs, streaming: streaming)
        end

        loaded.session
      end

      def self.load_provider_script(dir)
        stream_path = File.join(dir, "provider-script-stream.json")
        if File.exist?(stream_path)
          [JSON.parse(File.read(stream_path)), true]
        else
          [JSON.parse(File.read(File.join(dir, "provider-script.json"))), false]
        end
      end

      def self.drive_inputs(loaded, scripted, inputs, streaming: false)
        inputs.each do |input|
          loaded = drive_input(loaded, scripted, input, streaming: streaming)
        end
        loaded
      end

      def self.drive_input(loaded, scripted, input, streaming: false)
        if input.is_a?(Hash) && input.key?("compact")
          return append_compact(loaded, input.fetch("compact"))
        end
        if input.is_a?(Hash) && input.key?("revert")
          return append_revert(loaded, input.fetch("revert"))
        end
        if input.is_a?(Hash) && input.key?("fork")
          return fork_loaded(loaded, input.fetch("fork").fetch("at_seq"))
        end

        append_user_message(loaded, input)
        run_loop(loaded, scripted, streaming: streaming)
        loaded
      end

      def self.append_compact(loaded, compact)
        loaded.session.log.append(
          type: :compact,
          payload: {
            replaces: compact.fetch("replaces"),
            summary: compact.fetch("summary")
          }
        )
        loaded
      end

      def self.append_revert(loaded, revokes)
        loaded.session.log.append(type: :revert, payload: { revokes: revokes })
        loaded
      end

      def self.fork_loaded(loaded, at_seq)
        parent = loaded.session
        forked = parent.fork(at_seq: at_seq)
        verify_fork!(parent, forked, at_seq)
        loaded.with_session(forked)
      end

      def self.append_user_message(loaded, input)
        text = input.is_a?(Hash) ? input.fetch("user") : input
        loaded.session.log.append(
          type: :user_message,
          payload: Harnas::Events::UserMessage.new(text: text).to_h
        )
      end

      def self.run_loop(loaded, scripted, streaming: false)
        loop_kwargs = {
          session: loaded.session,
          projection: loaded.projection,
          runner: loaded.runner,
          max_turns: 3
        }
        if streaming
          loop_kwargs[:stream_provider] = scripted
        else
          loop_kwargs[:provider] = scripted
          loop_kwargs[:ingestor] = loaded.ingestor
        end
        Harnas::AgentLoop.new(**loop_kwargs).run
      end

      def self.verify_fork!(parent, forked, at_seq)
        expected_prefix = serialize_log(parent.log.first(at_seq + 1))
        actual_prefix   = serialize_log(forked.log.to_a)
        raise "fork prefix mismatch" unless actual_prefix == expected_prefix
        raise "forked_from mismatch" unless forked.metadata[:forked_from] == parent.id
        raise "forked_at_seq mismatch" unless forked.metadata[:forked_at_seq] == at_seq
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
      # spec/conformance/README.md (canonical compact JSON for the args).
      # Fixtures whose agent loop invokes tools get deterministic,
      # language-neutral output.
      def self.conformance_tool_handlers
        Hash.new do |_, name|
          next ->(_args) { raise "conformance tool error" } if name == "conformance.raise_error"

          ->(args) { "[conformance stub: #{name}(#{canonical_json(args)})]" }
        end
      end

      def self.canonical_json(value)
        JSON.generate(canonical_json_value(value))
      end

      def self.canonical_json_value(value)
        case value
        when Hash
          value.keys.map(&:to_s).sort.each_with_object({}) do |key, out|
            source_key = value.key?(key) ? key : key.to_sym
            out[key] = canonical_json_value(value[source_key])
          end
        when Array
          value.map { |item| canonical_json_value(item) }
        else
          value
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
