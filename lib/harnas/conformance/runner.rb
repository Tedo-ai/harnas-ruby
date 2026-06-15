# frozen_string_literal: true

require "json"
require "pathname"
require "tmpdir"
require "harnas/manifest"
require "harnas/tools/runner"
require "harnas/agent_loop"
require "harnas/events/user_message"
require "harnas/attachments"
require "harnas/hooks"
require "harnas/tools/builtin"
require "harnas/tools/snapshot"
require "harnas/projection"
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
        dir = File.expand_path(dir)
        projection_path = File.join(dir, "expected-projections.jsonl")
        return run_projection_fixture(dir) if File.exist?(projection_path)

        manifest = JSON.parse(File.read(File.join(dir, "manifest.json")))
        manifest.delete("fixture_version_added")
        manifest = resolve_fixture_paths(manifest, dir)
        script, streaming = load_provider_script(dir)
        inputs   = JSON.parse(File.read(File.join(dir, "inputs.json")))
        expected = load_expected(File.join(dir, "expected-log.jsonl"))
        expected_deltas_path = File.join(dir, "expected-deltas.jsonl")
        expected_strategy_events_path = File.join(dir, "expected-strategy-events.jsonl")
        expected_spawn_children_path = File.join(dir, "expected-spawn-children.json")
        expected_tool_descriptors_path = File.join(dir, "expected-tool-descriptors.json")

        actual, actual_deltas, actual_strategy_events, actual_tool_descriptors = Dir.chdir(dir) do
          run_agent_with_sidecars(
            manifest, script, inputs, streaming: streaming,
                                      attachment_store: load_attachment_store("."),
                                      expected_deltas_path: expected_deltas_path,
                                      expected_strategy_events_path: expected_strategy_events_path,
                                      expected_spawn_children_path: expected_spawn_children_path
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
        if diff.nil? && File.exist?(expected_tool_descriptors_path)
          descriptors = actual_tool_descriptors.map do |descriptor|
            descriptor.except("args_key_style")
          end
          diff = first_mismatch(
            descriptors,
            JSON.parse(File.read(expected_tool_descriptors_path))
          )
        end
        diff ||= credential_proxy_secret_diff(actual, dir)
        diff ||= isolation_repeat_diff(dir, manifest, script, inputs, streaming, expected)
        Result.new(
          fixture: File.basename(dir),
          passed: diff.nil?,
          diff: diff,
          actual: actual,
          expected: expected
        )
      end
      # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

      def self.isolation_repeat_diff(dir, manifest, script, inputs, streaming, expected)
        path = File.join(dir, "isolation.json")
        return nil unless File.exist?(path)

        repeat = JSON.parse(File.read(path)).fetch("repeat", 1).to_i
        return nil if repeat < 2

        (2..repeat).each do |index|
          actual, = Dir.chdir(dir) do
            run_agent_with_sidecars(
              manifest, script, inputs, streaming: streaming,
                                        attachment_store: load_attachment_store(".")
            )
          end
          diff = first_mismatch(actual, expected)
          return { at_seq: "repeat #{index}", actual: diff, expected: nil } unless diff.nil?
        end
        nil
      end

      def self.run_projection_fixture(dir)
        sessions, root = load_fixture_sessions(File.join(dir, "sessions"))
        expected = load_expected(File.join(dir, "expected-log.jsonl"))
        actual = serialize_log(root.log)
        diff = first_mismatch(actual, expected)
        diff ||= first_projection_mismatch(
          load_expected(File.join(dir, "expected-projections.jsonl")),
          sessions
        )
        Result.new(
          fixture: File.basename(dir),
          passed: diff.nil?,
          diff: diff,
          actual: actual,
          expected: expected
        )
      end

      def self.load_fixture_sessions(dir)
        sessions = {}
        root = nil
        Dir.children(dir).grep(/\.jsonl\z/).sort.each do |name|
          session = Harnas::Session.load(File.join(dir, name))
          sessions[session.id] = session
          next unless session.parent_session_id.nil?

          raise ArgumentError, "multiple root sessions in #{dir}" if root

          root = session
        end
        raise ArgumentError, "no root session in #{dir}" unless root

        [sessions, root]
      end

      def self.first_projection_mismatch(rows, sessions)
        rows.each_with_index do |row, index|
          actual = evaluate_projection(row.fetch("projection"), row.fetch("input"), sessions)
          expected = row.fetch("output")
          next if normalize(actual) == normalize(expected)

          return {
            at_seq: "projection #{index}",
            actual: actual,
            expected: expected
          }
        end
        nil
      end

      def self.evaluate_projection(name, input, sessions)
        case name
        when "delegation_tree"
          Harnas::Projection.delegation_tree(input, runtime: sessions)
        when "open_children"
          Harnas::Projection.open_children(input, runtime: sessions)
        when "descendant_timeline"
          Harnas::Projection.descendant_timeline(input, runtime: sessions)
        when "descendant_usage"
          Harnas::Projection.descendant_usage(input, runtime: sessions)
        else
          raise ArgumentError, "unknown projection #{name.inspect}"
        end
      end

      def self.fixture_version(spec_root)
        path = File.join(spec_root, "VERSION")
        return nil unless File.file?(path)

        File.readlines(path).each do |line|
          key, value = line.split(":", 2).map(&:strip)
          return value if key == "fixtures_version"
        end
        nil
      end

      def self.run_agent(manifest, script, inputs, streaming: false, attachment_store: nil)
        serialize_log(
          run_session(manifest, script, inputs, streaming: streaming,
                                                attachment_store: attachment_store).log
        )
      end

      def self.run_agent_with_sidecars(manifest, script, inputs, streaming: false, # rubocop:disable Metrics/MethodLength, Metrics/ParameterLists, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
                                       expected_deltas_path: nil,
                                       attachment_store: nil,
                                       expected_strategy_events_path: nil,
                                       expected_spawn_children_path: nil)
        needs_deltas = expected_deltas_path && File.exist?(expected_deltas_path)
        needs_strategy_events = expected_strategy_events_path &&
                                File.exist?(expected_strategy_events_path)
        needs_spawn_children = expected_spawn_children_path &&
                               File.exist?(expected_spawn_children_path)
        unless needs_deltas || needs_strategy_events || needs_spawn_children
          session = run_session(manifest, script, inputs, streaming: streaming,
                                                          attachment_store: attachment_store)
          return [serialize_log(session.log), [], [], session.metadata[:tools] || []]
        end

        Dir.mktmpdir("harnas-sidecars") do |dir|
          delta_path = File.join(dir, "session.deltas.jsonl")
          strategy_events_path = File.join(dir, "session.strategy-events.jsonl")
          session = run_session(
            manifest,
            script,
            inputs,
            streaming: streaming,
            delta_path: (delta_path if needs_deltas),
            attachment_store: attachment_store,
            strategy_events_path: (strategy_events_path if needs_strategy_events)
          )
          verify_spawn_children!(session, expected_spawn_children_path) if needs_spawn_children
          [
            serialize_log(session.log),
            needs_deltas ? load_expected(delta_path) : [],
            needs_strategy_events ? load_expected(strategy_events_path) : [],
            session.metadata[:tools] || []
          ]
        end
      end

      # rubocop:disable Metrics/MethodLength
      def self.run_session(manifest, script, inputs, streaming: false, session: nil, # rubocop:disable Metrics/ParameterLists
                           delta_path: nil, strategy_events_path: nil, attachment_store: nil)
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
          hook_handlers: conformance_hook_handlers,
          attachment_store: attachment_store || load_attachment_store(".")
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
        if input.is_a?(Hash) && input.key?("append_events")
          return append_events(loaded, input.fetch("append_events"))
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

      def self.append_events(loaded, events)
        Array(events).each do |event|
          loaded.session.log.append(type: event.fetch("type").to_sym,
                                    payload: normalize(event.fetch("payload")))
        end
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
          ids_before = loaded.session.log.map(&:id)
          reloaded = Harnas::Session.load(path)
          raise "event id preservation mismatch" unless ids_before == reloaded.log.map(&:id)

          verify_manifest_snapshot!(reloaded, manifest)
          loaded.with_session(reloaded)
        end
      end

      def self.verify_spawn_children!(session, path) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
        spec = JSON.parse(File.read(path))
        spawn = session.log.find do |event|
          event.type == :agent_spawn && event.payload[:task] == spec.fetch("task")
        end
        raise "missing agent_spawn for task #{spec.fetch("task")}" unless spawn

        child_id = spawn.payload.fetch(:child_session_id)
        child_sessions = session.metadata.fetch(:spawn_child_sessions, {})
        child = child_sessions.fetch(child_id) { raise "missing child Session #{child_id}" }
        unless child.parent_session_id == session.id &&
               child.spawn_id == spawn.payload.fetch(:spawn_id) &&
               child.spawned_by_event_id == spawn.payload.fetch(:spawned_by_event_id)
          raise "child reciprocity mismatch"
        end
        if child.root_session_id.to_s.empty? ||
           child.delegation_chain.empty?
          raise "child delegation metadata missing"
        end

        first = child.log.first
        return if first&.type == :user_message &&
                  first.payload[:text] == spec.fetch("child_initial_user_text")

        raise "child initial user_message mismatch"
      end

      def self.verify_manifest_snapshot!(session, expected_manifest)
        actual = normalize(session.metadata.fetch(:manifest))
        expected = normalize(expected_manifest)
        raise "manifest snapshot mismatch" unless actual == expected
      end

      def self.append_user_message(loaded, input)
        if input.is_a?(Hash) && input.key?("content")
          loaded.session.log.append(
            type: :user_message,
            payload: { content: input.fetch("content") }
          )
          return
        end
        text = input.is_a?(Hash) ? input.fetch("user") : input
        loaded.session.log.append(
          type: :user_message,
          payload: Harnas::Events::UserMessage.new(text: text).to_h
        )
      end

      def self.load_attachment_store(dir)
        store = Harnas::Attachments::MemoryStore.new
        path = File.join(dir, "attachments.json")
        return store unless File.exist?(path)

        JSON.parse(File.read(path)).each do |spec|
          store.put(File.binread(File.join(dir, spec.fetch("path"))),
                    spec.fetch("media_type"))
        end
        store
      end

      def self.run_loop(loaded, scripted, streaming: false)
        runner = loaded.runner
        loop_kwargs = {
          session: loaded.session,
          projection: loaded.projection,
          runner: runner,
          max_turns: 3
        }
        if streaming
          loop_kwargs[:stream_provider] = scripted
        else
          loop_kwargs[:provider] = scripted
          loop_kwargs[:ingestor] = loaded.ingestor
        end
        loop_kwargs[:provider_kind] = loaded.provider_kind
        Harnas::AgentLoop.new(**loop_kwargs).run
        loaded.session.metadata[:tools] =
          Harnas::Tools::Snapshot.descriptors(loaded.registry)
        return if runner.child_sessions.empty?

        loaded.session.metadata[:spawn_child_sessions] = runner.child_sessions
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
        register_conformance_builtins(handlers)
        handlers
      end

      def self.register_conformance_builtins(handlers)
        handlers["harnas.builtin.load_skill"] = Harnas::Tools::Builtin.method(:load_skill)
        handlers["harnas.builtin.read_file"] =
          Harnas::Tools::Builtin.handlers.fetch("harnas.builtin.read_file")
        handlers["harnas.builtin.write_file"] =
          Harnas::Tools::Builtin.handlers.fetch("harnas.builtin.write_file")
        handlers["harnas.builtin.edit_file"] =
          Harnas::Tools::Builtin.handlers.fetch("harnas.builtin.edit_file")
        handlers["harnas.builtin.bash_session"] =
          Harnas::Tools::Builtin.handlers.fetch("harnas.builtin.bash_session")
        handlers["harnas.builtin.fetch_url"] = fixture_fetch_url_handler
      end

      def self.fixture_fetch_url_handler
        lambda do |args|
          if args[:url] == "https://api.example.com/data"
            headers = args[:headers] || {}
            unless headers["Authorization"] == "Bearer SECRET-DO-NOT-LOG"
              raise "fetch_url missing credential proxy Authorization header"
            end

            next "fetched OK"
          end

          "[conformance stub: harnas.builtin.fetch_url(#{canonical_json(args)})]"
        end
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
          when "conformance.audit_post_tool_use", "conformance.audit_post_tool_use_variant"
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
          when "conformance.raise_hook", "conformance.raise_hook_variant"
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
            "timestamp" => event.timestamp,
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
          next if wildcard_match?(actual[i], expected[i])

          return {
            at_seq: i,
            actual: actual[i],
            expected: expected[i]
          }
        end
        nil
      end

      def self.wildcard_match?(actual, expected)
        actual = normalize_actual_for_expected(actual, expected)
        return actual == expected unless contains_generated_wildcard?(expected)

        wildcard_value_match?(actual, expected)
      end

      def self.normalize_actual_for_expected(actual, expected)
        return actual unless actual.is_a?(Hash) && expected.is_a?(Hash)

        actual = actual.dup
        actual.delete("timestamp") unless expected.key?("timestamp")
        actual
      end

      def self.contains_generated_wildcard?(value)
        JSON.generate(value).include?("<generated>")
      end

      def self.wildcard_value_match?(actual, expected)
        return !actual.nil? && actual != "" if expected == "<generated>"

        if actual.is_a?(Hash) && expected.is_a?(Hash)
          return false unless actual.keys.sort == expected.keys.sort

          return expected.all? { |key, value| wildcard_value_match?(actual[key], value) }
        end
        if actual.is_a?(Array) && expected.is_a?(Array)
          return false unless actual.size == expected.size

          return actual.zip(expected).all? { |a, e| wildcard_value_match?(a, e) }
        end
        actual == expected
      end

      def self.credential_proxy_secret_diff(actual, dir)
        return nil unless File.basename(dir) == "with-credential-proxy-injection"

        serialized = actual.map { |event| JSON.generate(event) }.join("\n")
        return nil unless serialized.include?("SECRET-DO-NOT-LOG")

        {
          at_seq: "redaction",
          actual: "serialized log contains SECRET-DO-NOT-LOG",
          expected: "serialized log must not contain SECRET-DO-NOT-LOG"
        }
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
