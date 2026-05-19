# frozen_string_literal: true

require "json"
require "tempfile"
require "harnas/manifest"
require "harnas/hooks"

RSpec.describe Harnas::Manifest do
  around do |example|
    saved = ENV.to_h
    %w[ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY].each { |key| ENV.delete(key) }
    example.run
  ensure
    ENV.replace(saved)
  end

  let(:basic_manifest) do
    {
      "harnas_version" => "0.1",
      "name" => "test_agent",
      "provider" => {
        "kind" => "mock",
        "max_tokens" => 1024
      },
      "tools" => [],
      "strategies" => []
    }
  end

  describe "version handling" do
    it "accepts version 0.1" do
      expect { described_class.load(basic_manifest) }.not_to raise_error
    end

    it "rejects an unsupported version" do
      manifest = basic_manifest.merge("harnas_version" => "9.9")
      expect { described_class.load(manifest) }
        .to raise_error(Harnas::Manifest::ValidationError)
    end
  end

  describe "schema validation" do
    it "resolves the schema from the bundled gem path" do
      ENV.delete("HARNAS_SPEC")

      bundled_schema = File.expand_path(
        "../../lib/harnas/schemas/agent-manifest.schema.json",
        __dir__
      )
      expect(described_class::SCHEMA_PATH).to eq(bundled_schema)
      expect(File.exist?(described_class::SCHEMA_PATH)).to be true
    end

    it "rejects a manifest missing required top-level fields" do
      expect { described_class.load({ "harnas_version" => "0.1", "name" => "x" }) }
        .to raise_error(Harnas::Manifest::ValidationError)
    end

    it "rejects a strategy name not matching Family::Name" do
      manifest = basic_manifest.merge(
        "strategies" => [{ "name" => "bogus" }]
      )
      expect { described_class.load(manifest) }
        .to raise_error(Harnas::Manifest::ValidationError)
    end
  end

  describe "source parsing" do
    it "accepts a Hash" do
      expect { described_class.load(basic_manifest) }.not_to raise_error
    end

    it "accepts a JSON String" do
      expect { described_class.load(JSON.generate(basic_manifest)) }.not_to raise_error
    end

    it "accepts a filesystem path" do
      Tempfile.create(["manifest", ".json"]) do |f|
        f.write(JSON.generate(basic_manifest))
        f.flush
        expect { described_class.load(f.path) }.not_to raise_error
      end
    end
  end

  describe "provider resolution" do
    it "builds a Projection + Provider + Ingestor triplet for :mock (CannedProvider)" do
      loaded = described_class.load(basic_manifest)
      expect(loaded.projection).to be_a(Harnas::Projections::Anthropic)
      expect(loaded.provider).to   be_a(Harnas::Benchmark::CannedProvider)
      expect(loaded.ingestor).to   be_a(Harnas::Ingestors::Anthropic)
    end

    it "requires api_keys for non-mock providers" do
      manifest = basic_manifest.merge(
        "provider" => { "kind" => "anthropic", "model" => "x", "max_tokens" => 100 }
      )
      expect { described_class.load(manifest) }
        .to raise_error(Harnas::Manifest::Error, /api_keys/)
    end

    it "accepts api_keys for anthropic" do
      manifest = basic_manifest.merge(
        "provider" => { "kind" => "anthropic", "model" => "claude-x", "max_tokens" => 100 }
      )
      loaded = described_class.load(manifest, api_keys: { anthropic: "sk-test" })
      expect(loaded.provider).to be_a(Harnas::Providers::Anthropic)
    end

    it "falls back to the provider's environment API key" do
      ENV["ANTHROPIC_API_KEY"] = "sk-env"
      manifest = basic_manifest.merge(
        "provider" => { "kind" => "anthropic", "model" => "claude-x", "max_tokens" => 100 }
      )

      loaded = described_class.load(manifest)

      expect(loaded.provider.instance_variable_get(:@api_key)).to eq("sk-env")
    end

    it "prefers an explicit api_key over the environment fallback" do
      ENV["ANTHROPIC_API_KEY"] = "sk-env"
      manifest = basic_manifest.merge(
        "provider" => { "kind" => "anthropic", "model" => "claude-x", "max_tokens" => 100 }
      )

      loaded = described_class.load(manifest, api_keys: { anthropic: "sk-explicit" })

      expect(loaded.provider.instance_variable_get(:@api_key)).to eq("sk-explicit")
    end

    it "accepts string-keyed explicit api_keys over the environment fallback" do
      ENV["ANTHROPIC_API_KEY"] = "sk-env"
      manifest = basic_manifest.merge(
        "provider" => { "kind" => "anthropic", "model" => "claude-x", "max_tokens" => 100 }
      )

      loaded = described_class.load(manifest, api_keys: { "anthropic" => "sk-string" })

      expect(loaded.provider.instance_variable_get(:@api_key)).to eq("sk-string")
    end
  end

  describe "tool registration" do
    it "registers manifest tools into a Registry backed by the provided handlers" do
      manifest = basic_manifest.merge(
        "tools" => [
          {
            "name" => "echo",
            "handler" => "acme.echo",
            "description" => "echoes",
            "input_schema" => { "type" => "object" }
          }
        ]
      )
      loaded = described_class.load(manifest, tool_handlers: {
                                      "acme.echo" => ->(args) { args[:text].to_s }
                                    })
      expect(loaded.registry.names).to eq(["echo"])
      expect(loaded.registry["echo"].call(text: "hi")).to eq("hi")
    end

    it "raises when a tool handler is unresolved" do
      manifest = basic_manifest.merge(
        "tools" => [
          {
            "name" => "echo", "handler" => "acme.missing",
            "description" => "x", "input_schema" => { "type" => "object" }
          }
        ]
      )
      expect { described_class.load(manifest, tool_handlers: {}) }
        .to raise_error(Harnas::Manifest::UnresolvedHandlerError, /acme.missing/)
    end
  end

  describe "strategy resolution" do
    it "resolves a canonical strategy name to its Ruby class with config" do
      manifest = basic_manifest.merge(
        "strategies" => [
          { "name" => "Compaction::MarkerTail",
            "config" => { "max_messages" => 20, "keep_recent" => 10 } }
        ]
      )
      loaded = described_class.load(manifest)
      inst   = loaded.strategies.first
      expect(inst.klass).to eq(Harnas::Strategies::Compaction::MarkerTail)
      expect(inst.config).to eq(max_messages: 20, keep_recent: 10)
    end

    it "rejects an unknown canonical strategy name at load time" do
      manifest = basic_manifest.merge(
        "strategies" => [{ "name" => "Fiction::Nonexistent" }]
      )
      expect { described_class.load(manifest) }
        .to raise_error(Harnas::Manifest::UnknownStrategyError, /Fiction::Nonexistent/)
    end

    it "resolves callable config fields via strategy_handlers" do
      prompt_called = false
      prompt = lambda do |_tu|
        prompt_called = true
        true
      end

      manifest = basic_manifest.merge(
        "strategies" => [
          { "name" => "Permission::HumanApproval",
            "config" => { "prompt" => "acme.cli_prompt" } }
        ]
      )
      loaded = described_class.load(manifest, strategy_handlers: { "acme.cli_prompt" => prompt })
      inst   = loaded.strategies.first
      # The prompt should have been substituted with the actual callable.
      expect(inst.config[:prompt]).to be(prompt)
      inst.config[:prompt].call(nil)
      expect(prompt_called).to be(true)
    end

    it "raises when a callable config field references an unresolved handler" do
      manifest = basic_manifest.merge(
        "strategies" => [
          { "name" => "Permission::HumanApproval",
            "config" => { "prompt" => "acme.missing" } }
        ]
      )
      expect { described_class.load(manifest, strategy_handlers: {}) }
        .to raise_error(Harnas::Manifest::UnresolvedHandlerError, /acme.missing/)
    end

    it "injects the bundle's projection/provider/ingestor into SummaryTail at install time" do
      manifest = basic_manifest.merge(
        "strategies" => [
          { "name" => "Compaction::SummaryTail",
            "config" => { "max_messages" => 20, "keep_recent" => 10 } }
        ]
      )
      loaded = described_class.load(manifest)
      inst   = loaded.strategies.first
      expect(inst.config[:projection]).to be(loaded.projection)
      expect(inst.config[:provider]).to   be(loaded.provider)
      expect(inst.config[:ingestor]).to   be(loaded.ingestor)
    end
  end

  describe "hook resolution" do
    it "resolves manifest hooks via hook_handlers and installs them" do
      calls = []
      manifest = basic_manifest.merge(
        "hooks" => [
          { "point" => ":post_tool_use", "handler" => "acme.audit",
            "config" => { "endpoint" => "memory" } }
        ]
      )
      handler = ->(**ctx) { calls << ctx[:config].fetch(:endpoint) }

      loaded = described_class.load(manifest, hook_handlers: { "acme.audit" => handler })
      loaded.install_strategies!
      loaded.session.hooks.invoke(:post_tool_use, session: loaded.session)

      expect(calls).to eq(["memory"])
    end

    it "raises when a manifest hook handler is unresolved" do
      manifest = basic_manifest.merge(
        "hooks" => [{ "point" => ":post_tool_use", "handler" => "acme.missing" }]
      )

      expect { described_class.load(manifest, hook_handlers: {}) }
        .to raise_error(Harnas::Manifest::UnresolvedHandlerError, /acme.missing/)
    end
  end

  describe "install step" do
    it "is side-effect-free on load; install_strategies! performs registration" do
      manifest = basic_manifest.merge(
        "strategies" => [
          { "name" => "Permission::AlwaysAllow" }
        ]
      )

      loaded = described_class.load(manifest)
      expect(loaded.session.hooks.handlers[:pre_tool_use]).to be_empty

      loaded.install_strategies!
      expect(loaded.session.hooks.handlers[:pre_tool_use]).not_to be_empty
      expect(Harnas::Hooks.handlers[:pre_tool_use]).to be_empty
    end
  end

  describe "Loaded conveniences" do
    it "exposes a prepared Session with the manifest name in metadata" do
      loaded = described_class.load(basic_manifest)
      expect(loaded.session).to be_a(Harnas::Session)
      expect(loaded.session.metadata).to include(manifest_name: "test_agent")
    end

    it "#runner returns a Tools::Runner bound to the registry" do
      loaded = described_class.load(basic_manifest)
      expect(loaded.runner).to be_a(Harnas::Tools::Runner)
    end
  end

  describe "system prompt" do
    let(:manifest_with_system) do
      basic_manifest.merge("system" => "You are a helpful assistant.")
    end

    it "threads a top-level `system` field through to the projection" do
      loaded = described_class.load(manifest_with_system)
      log    = Harnas::Log.new
      log.append(type: :user_message, payload: { text: "hi" })
      expect(loaded.projection.call(log)[:system]).to eq("You are a helpful assistant.")
    end

    it "validates that `system`, when present, is a non-empty string" do
      manifest = basic_manifest.merge("system" => "")
      expect { described_class.load(manifest) }
        .to raise_error(Harnas::Manifest::ValidationError, /system/)
    end
  end
end
