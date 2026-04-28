# frozen_string_literal: true

require "json"
require "json_schemer"

require "harnas/session"
require "harnas/tools/tool"
require "harnas/tools/registry"
require "harnas/tools/runner"

module Harnas
  # Loader for the Agent Manifest format (spec/18-agent-manifest.md).
  #
  # A manifest is a JSON document that fully describes an agent at
  # Layers 1 and 2 of the Harnas specification. This module reads a
  # manifest and produces a Loaded bundle with a prepared Session, a
  # configured Projection + Provider + Ingestor triplet, a registered
  # tool Registry, and a list of strategies ready to install.
  #
  # Loading is side-effect-free per R7 of spec/18-agent-manifest.md:
  # no hooks are registered, no network calls are made, no global
  # state is touched. The returned Loaded object exposes
  # #install_strategies! to perform the install step explicitly.
  module Manifest
    SUPPORTED_VERSIONS = %w[0.1].freeze

    # Resolution order for the spec's JSON Schema:
    #   1. HARNAS_SPEC env var pointing at a checkout of Tedo-ai/harnas
    #   2. ../../../harnas/schemas/... (sibling clone — coordinator layout)
    #   3. ../../../spec/schemas/...   (legacy monorepo internal layout)
    SCHEMA_PATH =
      if ENV["HARNAS_SPEC"]
        File.join(ENV["HARNAS_SPEC"], "schemas", "agent-manifest.schema.json")
      elsif File.exist?(File.expand_path("../../../harnas/schemas/agent-manifest.schema.json", __dir__))
        File.expand_path("../../../harnas/schemas/agent-manifest.schema.json", __dir__)
      else
        File.expand_path("../../../spec/schemas/agent-manifest.schema.json", __dir__)
      end

    class Error < StandardError; end
    class ValidationError < Error; end
    class UnsupportedVersionError < Error; end
    class UnknownProviderError < Error; end
    class UnknownStrategyError < Error; end
    class UnresolvedHandlerError < Error; end

    # Public: load a manifest and return a Loaded bundle.
    #
    # source           - a Hash, JSON String, or Pathname-like String pointing
    #                    to a JSON file.
    # tool_handlers:   - Hash mapping tool handler symbolic names to callables
    #                    of the form #call(arguments_hash) -> String.
    # strategy_handlers: - Hash mapping strategy-scoped callable names (e.g. a
    #                    HumanApproval prompt name) to callables.
    # api_keys:        - Hash mapping provider kinds (symbols) to API keys;
    #                    required for non-mock providers.
    def self.load(source, tool_handlers: {}, strategy_handlers: {}, api_keys: {})
      manifest = parse_source(source)
      validate!(manifest)
      check_version!(manifest["harnas_version"])

      registry        = build_registry(manifest["tools"], tool_handlers: tool_handlers)
      provider_bundle = build_provider(
        manifest["provider"],
        api_keys: api_keys,
        registry: registry,
        system: manifest["system"]
      )
      strategies = build_strategies(
        manifest["strategies"],
        strategy_handlers: strategy_handlers,
        provider_bundle: provider_bundle
      )

      Loaded.new(
        name: manifest["name"],
        session: Harnas::Session.create(metadata: { manifest_name: manifest["name"] }),
        projection: provider_bundle[:projection],
        provider: provider_bundle[:provider],
        ingestor: provider_bundle[:ingestor],
        registry: registry,
        strategies: strategies
      )
    end

    # A prepared agent. Side-effect-free until #install_strategies! is called.
    class Loaded
      attr_reader :name, :session, :projection, :provider, :ingestor,
                  :registry, :strategies

      def initialize(name:, session:, projection:, provider:, ingestor:,
                     registry:, strategies:)
        @name       = name
        @session    = session
        @projection = projection
        @provider   = provider
        @ingestor   = ingestor
        @registry   = registry
        @strategies = strategies
      end

      # Install every manifest-declared strategy onto Harnas::Hooks.
      # Returns the array of handler objects in install order (so they
      # can be removed individually via Harnas::Hooks.off).
      def install_strategies!
        @strategies.map(&:install)
      end

      # Convenience: build a runner + AgentLoop with the bundle's parts.
      # Harnas::Tools::Runner takes the registry positionally.
      def runner
        Harnas::Tools::Runner.new(@registry)
      end
    end

    # A strategy declaration ready to install. #install delegates to the
    # canonical class's install method with the resolved config.
    class StrategyInstallation
      attr_reader :klass, :config

      def initialize(klass:, config:)
        @klass  = klass
        @config = config
      end

      def install
        @klass.install(**@config)
      end
    end

    # Maps manifest provider `kind` to the Layer 1 class triplet.
    # Extension point: a consumer's downstream gem can add entries for
    # providers not in the reference set. The built-in mapping covers
    # exactly the providers the reference implementation ships.
    PROVIDER_KINDS = {
      "anthropic" => {
        projection: "harnas/projections/anthropic",
        provider: "harnas/providers/anthropic",
        ingestor: "harnas/ingestors/anthropic",
        projection_class: "Harnas::Projections::Anthropic",
        provider_class: "Harnas::Providers::Anthropic",
        ingestor_class: "Harnas::Ingestors::Anthropic",
        api_key_required: true
      },
      "openai" => {
        projection: "harnas/projections/openai",
        provider: "harnas/providers/openai",
        ingestor: "harnas/ingestors/openai",
        projection_class: "Harnas::Projections::OpenAI",
        provider_class: "Harnas::Providers::OpenAI",
        ingestor_class: "Harnas::Ingestors::OpenAI",
        api_key_required: true
      },
      "gemini" => {
        projection: "harnas/projections/gemini",
        provider: "harnas/providers/gemini",
        ingestor: "harnas/ingestors/gemini",
        projection_class: "Harnas::Projections::Gemini",
        provider_class: "Harnas::Providers::Gemini",
        ingestor_class: "Harnas::Ingestors::Gemini",
        api_key_required: true
      },
      "mock" => {
        projection: "harnas/projections/anthropic",
        provider: "harnas/benchmark/canned_provider",
        ingestor: "harnas/ingestors/anthropic",
        projection_class: "Harnas::Projections::Anthropic",
        provider_class: "Harnas::Benchmark::CannedProvider",
        ingestor_class: "Harnas::Ingestors::Anthropic",
        api_key_required: false
      }
    }.freeze

    # Canonical strategy catalog. Extension point: consumers MAY register
    # additional entries for strategies they ship downstream, but Layer 2
    # canonicals from the spec live here verbatim.
    STRATEGY_CLASSES = {
      "Compaction::MarkerTail" =>
        "harnas/strategies/compaction/marker_tail",
      "Compaction::TokenMarkerTail" =>
        "harnas/strategies/compaction/token_marker_tail",
      "Compaction::SummaryTail" =>
        "harnas/strategies/compaction/summary_tail",
      "Compaction::ToolOutputCap" =>
        "harnas/strategies/compaction/tool_output_cap",
      "Permission::AlwaysAllow" =>
        "harnas/strategies/permission/always_allow",
      "Permission::DenyByName" =>
        "harnas/strategies/permission/deny_by_name",
      "Permission::HumanApproval" =>
        "harnas/strategies/permission/human_approval"
    }.freeze

    STRATEGY_CLASS_NAMES = {
      "Compaction::MarkerTail" =>
        "Harnas::Strategies::Compaction::MarkerTail",
      "Compaction::TokenMarkerTail" =>
        "Harnas::Strategies::Compaction::TokenMarkerTail",
      "Compaction::SummaryTail" =>
        "Harnas::Strategies::Compaction::SummaryTail",
      "Compaction::ToolOutputCap" =>
        "Harnas::Strategies::Compaction::ToolOutputCap",
      "Permission::AlwaysAllow" =>
        "Harnas::Strategies::Permission::AlwaysAllow",
      "Permission::DenyByName" =>
        "Harnas::Strategies::Permission::DenyByName",
      "Permission::HumanApproval" =>
        "Harnas::Strategies::Permission::HumanApproval"
    }.freeze

    # Which config fields each strategy expects as external-world callables.
    # Manifest values for these fields MUST be Strings (symbolic names) that
    # the loader resolves against the strategy_handlers map at load time.
    CALLABLE_CONFIG_FIELDS = {
      "Permission::HumanApproval" => %i[prompt]
    }.freeze

    # For Autocompact, the projection/provider/ingestor parameters are not
    # supplied by the manifest — they're taken from the main bundle to
    # reuse the same stack. Those fields are injected at install time,
    # not read from config.
    IMPLICIT_BUNDLE_FIELDS = {
      "Compaction::SummaryTail" => %i[projection provider ingestor]
    }.freeze

    def self.parse_source(source)
      case source
      when Hash   then source
      when String then parse_string_source(source)
      else             raise Error, "unsupported manifest source: #{source.class}"
      end
    end

    def self.parse_string_source(source)
      if source.start_with?("{") || source.include?("\n")
        JSON.parse(source)
      else
        JSON.parse(File.read(source))
      end
    end

    def self.validate!(manifest)
      schemer = JSONSchemer.schema(File.read(SCHEMA_PATH))
      errors  = schemer.validate(manifest).to_a
      return if errors.empty?

      message = errors.map { |e| "#{e["data_pointer"]}: #{e["error"]}" }.join("; ")
      raise ValidationError, "manifest failed schema validation: #{message}"
    end

    def self.check_version!(version)
      return if SUPPORTED_VERSIONS.include?(version)

      raise UnsupportedVersionError,
            "manifest version #{version.inspect} not in supported #{SUPPORTED_VERSIONS.inspect}"
    end

    def self.build_provider(provider_spec, api_keys:, registry:, system: nil)
      kind = provider_spec["kind"]
      info = PROVIDER_KINDS[kind] or raise UnknownProviderError,
                                           "unknown provider kind: #{kind.inspect}"

      require info[:projection]
      require info[:provider]
      require info[:ingestor]

      projection_klass = Object.const_get(info[:projection_class])
      provider_klass   = Object.const_get(info[:provider_class])
      ingestor_klass   = Object.const_get(info[:ingestor_class])

      {
        projection: build_projection_instance(projection_klass, provider_spec, registry, system),
        provider: build_provider_instance(provider_klass, kind, info, api_keys),
        ingestor: ingestor_klass.new
      }
    end

    def self.build_projection_instance(projection_klass, provider_spec, registry, system = nil)
      params = projection_klass.instance_method(:initialize).parameters.map { |(_, n)| n }
      kwargs = {}
      kwargs[:model]      = provider_spec["model"]      if params.include?(:model)
      kwargs[:max_tokens] = provider_spec["max_tokens"] if params.include?(:max_tokens)
      kwargs[:registry] = registry if params.include?(:registry) && registry
      kwargs[:system]   = system   if params.include?(:system)   && system
      projection_klass.new(**kwargs)
    end

    def self.build_provider_instance(provider_klass, kind, info, api_keys)
      if info[:api_key_required]
        key = api_keys[kind.to_sym] || api_keys[kind]
        raise Error, "api_keys[#{kind.inspect}] is required for provider #{kind}" if key.nil?

        provider_klass.new(api_key: key)
      else
        provider_klass.new
      end
    end

    def self.build_registry(tools_spec, tool_handlers:)
      registry = Harnas::Tools::Registry.new

      tools_spec.each do |tool|
        handler_name = tool["handler"]
        handler      = tool_handlers[handler_name] ||
                       (raise UnresolvedHandlerError,
                              "tool handler #{handler_name.inspect} not in tool_handlers")

        registry.register(
          Harnas::Tools::Tool.new(
            name: tool["name"],
            description: tool["description"],
            input_schema: symbolize_schema(tool["input_schema"]),
            &handler
          )
        )
      end

      registry
    end

    def self.symbolize_schema(schema)
      case schema
      when Hash  then schema.each_with_object({}) { |(k, v), h| h[k.to_sym] = symbolize_schema(v) }
      when Array then schema.map { |v| symbolize_schema(v) }
      else            schema
      end
    end

    def self.build_strategies(strategies_spec, strategy_handlers:, provider_bundle:)
      strategies_spec.map do |strategy|
        name   = strategy["name"]
        path   = STRATEGY_CLASSES[name] or
          raise UnknownStrategyError, "unknown canonical strategy: #{name.inspect}"
        require path

        klass  = Object.const_get(STRATEGY_CLASS_NAMES.fetch(name))
        config = resolve_config(name, strategy.fetch("config", {}),
                                strategy_handlers, provider_bundle)

        StrategyInstallation.new(klass: klass, config: config)
      end
    end

    def self.resolve_config(strategy_name, raw_config, strategy_handlers, provider_bundle)
      config = raw_config.each_with_object({}) { |(k, v), h| h[k.to_sym] = v }

      Array(CALLABLE_CONFIG_FIELDS[strategy_name]).each do |field|
        handler_name = config[field] or next
        handler      = strategy_handlers[handler_name] ||
                       raise_unresolved_strategy_handler(strategy_name, field, handler_name)
        config[field] = handler
      end

      Array(IMPLICIT_BUNDLE_FIELDS[strategy_name]).each do |field|
        config[field] = provider_bundle.fetch(field)
      end

      config
    end

    def self.raise_unresolved_strategy_handler(strategy_name, field, handler_name)
      raise UnresolvedHandlerError,
            "strategy handler #{handler_name.inspect} " \
            "(for #{strategy_name} #{field}) not in strategy_handlers"
    end
  end
end
