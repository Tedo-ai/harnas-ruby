# frozen_string_literal: true

require "json"
require "pathname"
require "tmpdir"
require "harnas/manifest"
require "harnas/tools/runner"
require "harnas/agent_loop"
require "harnas/events/user_message"
require "harnas/hooks"
require "harnas/tools/builtin"
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
    # rubocop:disable Metrics/ModuleLength
    module Runner
      Result = Data.define(:fixture, :passed, :diff, :actual, :expected) do
        def summary
          return "#{fixture}  ok (#{actual.size} events)" if passed

          "#{fixture}  FAIL at seq #{diff[:at_seq]}"
        end
      end

      # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      def self.run(dir)
        manifest = JSON.parse(File.read(File.join(dir, "manifest.json")))
        manifest = resolve_fixture_paths(manifest, dir)
        script, streaming = load_provider_script(dir)
        inputs   = JSON.parse(File.read(File.join(dir, "inputs.json")))
        expected = load_expected(File.join(dir, "expected-log.jsonl"))
        expected_deltas_path = File.join(dir, "expected-deltas.jsonl")
        expected_strategy_events_path = File.join(dir, "expected-strategy-events.jsonl")

        actual, actual_deltas, actual_strategy_events = Dir.chdir(dir) do
          run_agent_with_sidecars(
            manifest, script, inputs, streaming: streaming,
                                      expected_deltas_path: expected_deltas_path,
                                      expected_strategy_events_path: expected_strategy_events_path
          )
        end

        diff = first_mismatch(actual, expected)
        if diff.nil? && File.exist?(expected_deltas_path)
          diff = first_mismatch(actual_deltas, load_expected(expected_deltas_path))
        end
        if diff.nil? && File.exist?(expected_strategy_events_path)
          diff = first_mismatch(
            actual_strategy_events,
            load_expected(expected_strategy_events_path)
          )
        end
        Result.new(
          fixture: File.basename(dir),
          passed: diff.nil?,
          diff: diff,
          actual: actual,
          expected: expected
        )
      end
      # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

      def self.run_agent(manifest, script, inputs, streaming: false)
        serialize_log(run_session(manifest, script, inputs, streaming: streaming).log)
      end

      def self.run_agent_with_sidecars(manifest, script, inputs, streaming: false,
                                       expected_deltas_path: nil,
                                       expected_strategy_events_path: nil)
        needs_deltas = expected_deltas_path && File.exist?(expected_deltas_path)
        needs_strategy_events = expected_strategy_events_path &&
                                File.exist?(expected_strategy_events_path)
        return [run_agent(manifest, script, inputs, streaming: streaming), [], []] \
          unless needs_deltas || needs_strategy_events

        Dir.mktmpdir("harnas-sidecars") do |dir|
          delta_path = File.join(dir, "session.deltas.jsonl")
          strategy_events_path = File.join(dir, "session.strategy-events.jsonl")
          session = run_session(
            manifest,
            script,
            inputs,
            streaming: streaming,
            delta_path: (delta_path if needs_deltas),
            strategy_events_path: (strategy_events_path if needs_strategy_events)
          )
          [
            serialize_log(session.log),
            needs_deltas ? load_expected(delta_path) : [],
            needs_strategy_events ? load_expected(strategy_events_path) : []
          ]
        end
      end

      # rubocop:disable Metrics/MethodLength
      def self.run_session(manifest, script, inputs, streaming: false, session: nil,
                           delta_path: nil, strategy_events_path: nil)
        scripted = if streaming
                     ScriptedStreamProvider.new(streams: script)
                   else
                     ScriptedProvider.new(responses: script)
                   end
        loaded   = Harnas::Manifest.load(
          manifest,
          api_keys: conformance_api_keys,
          tool_handlers: conformance_tool_handlers,
          strategy_handlers: conformance_strategy_handlers,
          hook_handlers: conformance_hook_handlers
        )
        loaded = loaded.with_session(session) if session
        if delta_path
          Harnas::Observation::DeltaLogger.new(
            path: delta_path,
            observation: loaded.session.observation
          )
        end
        if strategy_events_path
          StrategyEventCollector.new(
            path: strategy_events_path,
            observation: loaded.session.observation
          )
        end

        Harnas::Hooks.scoped do
          loaded.install_strategies!
          loaded = drive_inputs(loaded, scripted, inputs, manifest: manifest, streaming: streaming)
        end

        loaded.session
      end
      # rubocop:enable Metrics/MethodLength

      def self.load_provider_script(dir)
        stream_path = File.join(dir, "provider-script-stream.json")
        if File.exist?(stream_path)
          [JSON.parse(File.read(stream_path)), true]
        else
          [JSON.parse(File.read(File.join(dir, "provider-script.json"))), false]
        end
      end

      def self.drive_inputs(loaded, scripted, inputs, manifest:, streaming: false)
        inputs.each do |input|
          loaded = drive_input(loaded, scripted, input, manifest: manifest, streaming: streaming)
        end
        loaded
      end

      def self.drive_input(loaded, scripted, input, manifest:, streaming: false)
        if input.is_a?(Hash) && input.key?("compact")
          return append_compact(loaded, input.fetch("compact"))
        end
        if input.is_a?(Hash) && input.key?("revert")
          return append_revert(loaded, input.fetch("revert"))
        end
        if input.is_a?(Hash) && input.key?("fork")
          return fork_loaded(loaded, input.fetch("fork").fetch("at_seq"))
        end
        return save_load(loaded, manifest: manifest) if input.is_a?(Hash) && input.key?("save_load")

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

      def self.save_load(loaded, manifest:)
        Dir.mktmpdir("harnas-save-load") do |dir|
          path = File.join(dir, "session.jsonl")
          loaded.session.save(path)
          reloaded = Harnas::Session.load(path)
          verify_manifest_snapshot!(reloaded, manifest)
          loaded.with_session(reloaded)
        end
      end

      def self.verify_manifest_snapshot!(session, expected_manifest)
        actual = normalize(session.metadata.fetch(:manifest))
        expected = normalize(expected_manifest)
        raise "manifest snapshot mismatch" unless actual == expected
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
        handlers = Hash.new do |_, name|
          next ->(_args) { raise "conformance tool error" } if name == "conformance.raise_error"
          if name == "conformance.echo_config"
            next lambda { |_args, config:|
              "[conformance config: #{canonical_json(config)}]"
            }
          end

          ->(args) { "[conformance stub: #{name}(#{canonical_json(args)})]" }
        end
        handlers["harnas.builtin.load_skill"] = Harnas::Tools::Builtin.method(:load_skill)
        handlers["harnas.builtin.write_file"] =
          Harnas::Tools::Builtin.handlers.fetch("harnas.builtin.write_file")
        handlers["harnas.builtin.edit_file"] =
          Harnas::Tools::Builtin.handlers.fetch("harnas.builtin.edit_file")
        handlers["harnas.builtin.bash_session"] =
          Harnas::Tools::Builtin.handlers.fetch("harnas.builtin.bash_session")
        handlers
      end

      def self.resolve_fixture_paths(manifest, fixture_dir)
        updated = Marshal.load(Marshal.dump(manifest))
        updated.fetch("tools", []).each do |tool|
          config = tool["config"]
          next unless config.is_a?(Hash)

          resolve_fixture_config_path!(config, "skills_dir", fixture_dir)
          resolve_fixture_config_path!(config, "cwd", fixture_dir)
        end
        updated
      end

      def self.resolve_fixture_config_path!(config, key, fixture_dir)
        return unless config[key].is_a?(String)
        return if Pathname.new(config[key]).absolute?

        config[key] = File.expand_path(config[key], fixture_dir)
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

      def self.conformance_hook_handlers
        Hash.new do |_, name|
          case name
          when "conformance.audit_post_tool_use"
            lambda do |session:, tool_use:, tool_result:, **_|
              session.log.append(
                type: :annotation,
                payload: {
                  kind: "conformance.hook",
                  data: {
                    tool_use_id: tool_use.payload[:id],
                    result_seq: tool_result.seq
                  }
                }
              )
            end
          when "conformance.raise_hook"
            ->(**_) { raise "conformance hook failure" }
          else
            raise Harnas::Manifest::UnresolvedHandlerError,
                  "hook handler #{name.inspect} not in hook_handlers"
          end
        end
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

      class StrategyEventCollector
        def initialize(path:, observation:)
          @path = path
          @index = 0
          observation.subscribe(method(:call))
        end

        def call(event_name, payload)
          return unless %i[strategy_started strategy_completed].include?(event_name)

          File.open(@path, "a") do |io|
            io.puts JSON.generate(
              index: @index,
              event: event_name.to_s,
              payload: Runner.normalize(payload)
            )
          end
          @index += 1
        end
      end
    end
    # rubocop:enable Metrics/ModuleLength
  end
end
