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
  # no hooks are registered, no network calls are made, no process-global
  # state is touched. The returned Loaded object exposes
  # #install_strategies! to perform the install step explicitly.
  module Manifest # rubocop:disable Metrics/ModuleLength
    SUPPORTED_VERSIONS = %w[0.1].freeze

    # Resolution order for the spec's JSON Schema:
    #   1. Bundled gem path — works for standalone gem installs.
    #   2. HARNAS_SPEC env var pointing at a checkout of Tedo-ai/harnas.
    #   3. ../../../harnas/schemas/... (sibling clone — coordinator layout).
    #   4. ../../../spec/schemas/...   (legacy monorepo internal layout).
    SCHEMA_PATH = [
      File.join(__dir__, "schemas", "agent-manifest.schema.json"),
      ENV.fetch("HARNAS_SPEC", nil) && File.join(ENV.fetch("HARNAS_SPEC", nil),
                                                 "schemas", "agent-manifest.schema.json"),
      File.expand_path("../../../harnas/schemas/agent-manifest.schema.json", __dir__),
      File.expand_path("../../../spec/schemas/agent-manifest.schema.json", __dir__)
    ].compact.find { |path| File.exist?(path) }

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
    # api_keys:        - Hash mapping provider kinds (symbols) to API keys.
    #                    Explicit values override ENV fallbacks. Non-mock
    #                    providers require either api_keys[kind] or the
    #                    matching provider env var.
    # rubocop:disable Metrics/MethodLength
    def self.load(source, tool_handlers: {}, strategy_handlers: {}, hook_handlers: {},
                  api_keys: {}, args_key_style: :symbol, attachment_store: nil)
      manifest = validated_manifest(source)
      check_version!(manifest["harnas_version"])
      default_args_key_style = normalize_args_key_style(args_key_style)

      registry = build_registry(
        manifest["tools"],
        tool_handlers: tool_handlers,
        args_key_style: default_args_key_style
      )
      provider_bundle = build_provider(
        manifest["provider"],
        api_keys: api_keys,
        registry: registry,
        system: manifest["system"],
        attachment_store: attachment_store
      )
      strategies = build_strategies(
        manifest["strategies"],
        strategy_handlers: strategy_handlers,
        provider_bundle: provider_bundle
      )
      hooks = build_hooks(manifest.fetch("hooks", []), hook_handlers: hook_handlers)

      Loaded.new(
        name: manifest["name"],
        session: Harnas::Session.create(
          metadata: { manifest_name: manifest["name"], manifest: manifest_snapshot(manifest) }
        ),
        projection: provider_bundle[:projection],
        provider: provider_bundle[:provider],
        stream_provider: provider_bundle[:stream_provider],
        ingestor: provider_bundle[:ingestor],
        registry: registry,
        strategies: strategies,
        hooks: hooks
      )
    end

    def self.validated_manifest(source)
      manifest = parse_source(source)
      validate_tool_descriptor_types!(manifest["tools"]) if manifest.is_a?(Hash)
      validate!(manifest)
      manifest
    end
    # rubocop:enable Metrics/MethodLength

    # A prepared agent. Side-effect-free until #install_strategies! is called.
    class Loaded
      attr_reader :name, :session, :projection, :provider, :stream_provider, :ingestor,
                  :registry, :strategies, :hooks

      def initialize(name:, session:, projection:, provider:, ingestor:, # rubocop:disable Metrics/ParameterLists
                     registry:, strategies:, hooks: [], stream_provider: nil)
        @name            = name
        @session         = session
        @projection      = projection
        @provider        = provider
        @stream_provider = stream_provider
        @ingestor        = ingestor
        @registry        = registry
        @strategies      = strategies
        @hooks           = hooks
      end

      # Install every manifest-declared strategy onto this Loaded Session.
      # Returns the array of handler objects in install order (so they
      # can be removed individually via session.hooks.off).
      def install_strategies!
        @strategies.map { |strategy| strategy.install(@session) } +
          @hooks.map { |hook| hook.install(@session) }
      end

      # Convenience: build a runner + AgentLoop with the bundle's parts.
      # Harnas::Tools::Runner takes the registry positionally.
      def runner
        @runner ||= Harnas::Tools::Runner.new(@registry)
      end

      def with_session(session)
        self.class.new(
          name: @name,
          session: session,
          projection: @projection,
          provider: @provider,
          stream_provider: @stream_provider,
          ingestor: @ingestor,
          registry: @registry,
          strategies: @strategies,
          hooks: @hooks
        )
      end
    end

    # A strategy declaration ready to install. #install delegates to the
    # canonical class's install method with the resolved config.
    class StrategyInstallation
      attr_reader :klass, :config, :on_error, :name

      def initialize(klass:, config:, on_error: :isolate, name: nil)
        @klass  = klass
        @config = config
        @on_error = on_error.to_sym
        @name = name || klass.name
      end

      def install(session)
        before = snapshot_handlers(session)
        handler = session.install(@klass, **@config)
        point = installed_point(session, before, handler)
        session.hooks.off(point, handler)
        session.hooks.on(point, handler, on_error: @on_error, name: @name, source: :strategy)
      end

      private

      def snapshot_handlers(session)
        session.hooks.handlers.transform_values(&:dup)
      end

      def installed_point(session, before, handler)
        session.hooks.handlers.each_pair do |point, handlers|
          return point if handlers.include?(handler) && !Array(before[point]).include?(handler)
        end
        klass.name.include?("Permission") ? :pre_tool_use : :pre_projection
      end
    end

    class HookInstallation
      attr_reader :point, :handler, :config, :on_error, :name

      def initialize(point:, handler:, config:, on_error:, name:)
        @point = point.to_sym
        @handler = handler
        @config = config
        @on_error = on_error.to_sym
        @name = name
      end

      def install(session)
        callable = build_callable(session)
        session.hooks.on(@point, callable, on_error: @on_error, name: @name, source: :hook)
      end

      private

      def build_callable(session)
        if @handler.respond_to?(:install)
          installed = @handler.install(session, **@config)
          return installed if installed.respond_to?(:call)
        end

        lambda do |**ctx|
          unless @handler.respond_to?(:call)
            raise UnresolvedHandlerError, "hook handler #{@name.inspect} is not callable"
          end

          @handler.call(**ctx, config: @config)
        end
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
        stream_provider: "harnas/providers/anthropic_stream_live",
        ingestor: "harnas/ingestors/anthropic",
        projection_class: "Harnas::Projections::Anthropic",
        provider_class: "Harnas::Providers::Anthropic",
        stream_provider_class: "Harnas::Providers::AnthropicStreamLive",
        ingestor_class: "Harnas::Ingestors::Anthropic",
        api_key_required: true
      },
      "openai" => {
        projection: "harnas/projections/openai",
        provider: "harnas/providers/openai",
        stream_provider: "harnas/providers/openai_stream_live",
        ingestor: "harnas/ingestors/openai",
        projection_class: "Harnas::Projections::OpenAI",
        provider_class: "Harnas::Providers::OpenAI",
        stream_provider_class: "Harnas::Providers::OpenAIStreamLive",
        ingestor_class: "Harnas::Ingestors::OpenAI",
        api_key_required: true
      },
      "ollama" => {
        projection: "harnas/projections/openai",
        provider: "harnas/providers/ollama",
        stream_provider: "harnas/providers/ollama_stream",
        ingestor: "harnas/ingestors/openai",
        projection_class: "Harnas::Projections::OpenAI",
        provider_class: "Harnas::Providers::Ollama",
        stream_provider_class: "Harnas::Providers::OllamaStream",
        ingestor_class: "Harnas::Ingestors::OpenAI",
        api_key_required: false
      },
      "gemini" => {
        projection: "harnas/projections/gemini",
        provider: "harnas/providers/gemini",
        stream_provider: "harnas/providers/gemini_stream_live",
        ingestor: "harnas/ingestors/gemini",
        projection_class: "Harnas::Projections::Gemini",
        provider_class: "Harnas::Providers::Gemini",
        stream_provider_class: "Harnas::Providers::GeminiStreamLive",
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
        "harnas/strategies/permission/human_approval",
      "sandbox/write" =>
        "harnas/strategies/sandbox/write",
      "sandbox/network" =>
        "harnas/strategies/sandbox/network",
      "credential/proxy" =>
        "harnas/strategies/credential/proxy",
      "guard/repetition" =>
        "harnas/strategies/guard/repetition",
      "guard/timeout" =>
        "harnas/strategies/guard/timeout",
      "guard/health" =>
        "harnas/strategies/guard/health",
      "guard/cost_budget" =>
        "harnas/strategies/guard/cost_budget"
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
        "Harnas::Strategies::Permission::HumanApproval",
      "sandbox/write" =>
        "Harnas::Strategies::Sandbox::Write",
      "sandbox/network" =>
        "Harnas::Strategies::Sandbox::Network",
      "credential/proxy" =>
        "Harnas::Strategies::Credential::Proxy",
      "guard/repetition" =>
        "Harnas::Strategies::Guard::Repetition",
      "guard/timeout" =>
        "Harnas::Strategies::Guard::Timeout",
      "guard/health" =>
        "Harnas::Strategies::Guard::Health",
      "guard/cost_budget" =>
        "Harnas::Strategies::Guard::CostBudget"
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

    def self.build_provider(provider_spec, api_keys:, registry:, system: nil,
                            attachment_store: nil)
      kind = provider_spec["kind"]
      info = PROVIDER_KINDS[kind] or raise UnknownProviderError,
                                           "unknown provider kind: #{kind.inspect}"

      require info[:projection]
      require info[:provider]
      require info[:ingestor]
      require info[:stream_provider] if info[:stream_provider]

      classes          = provider_classes(info)
      api_keys         = resolve_api_keys(api_keys)

      {
        projection: build_projection_instance(classes[:projection], provider_spec, registry,
                                              system, attachment_store),
        provider: build_provider_instance(classes[:provider], kind, info, api_keys,
                                          provider_spec),
        stream_provider: build_stream_provider_instance(classes[:stream_provider], kind, info,
                                                        api_keys, provider_spec),
        ingestor: classes[:ingestor].new
      }
    end

    def self.provider_classes(info)
      {
        projection: Object.const_get(info[:projection_class]),
        provider: Object.const_get(info[:provider_class]),
        stream_provider: stream_provider_class(info),
        ingestor: Object.const_get(info[:ingestor_class])
      }
    end

    def self.build_projection_instance(projection_klass, provider_spec, registry, system = nil,
                                       attachment_store = nil)
      params = projection_klass.instance_method(:initialize).parameters.map { |(_, n)| n }
      kwargs = {}
      kwargs[:model]      = provider_spec["model"]      if params.include?(:model)
      kwargs[:max_tokens] = provider_spec["max_tokens"] if params.include?(:max_tokens)
      kwargs[:registry] = registry if params.include?(:registry) && registry
      kwargs[:system]   = system   if params.include?(:system)   && system
      kwargs[:attachment_store] = attachment_store if params.include?(:attachment_store) &&
                                                      attachment_store
      add_projection_capability_kwargs(kwargs, params, provider_spec)
      projection_klass.new(**kwargs)
    end

    def self.add_projection_capability_kwargs(kwargs, params, provider_spec)
      kwargs[:provider_kind] = provider_spec["kind"] if params.include?(:provider_kind)
      if params.include?(:capabilities)
        kwargs[:capabilities] = provider_spec.fetch("capabilities", {})
      end
      return unless params.include?(:capability_mismatch_behavior)

      kwargs[:capability_mismatch_behavior] =
        provider_spec.fetch("capability_mismatch_behavior", "metadata_fallback")
    end

    def self.build_provider_instance(provider_klass, kind, info, api_keys, provider_spec)
      params = provider_klass.instance_method(:initialize).parameters.map { |(_, n)| n }
      kwargs = {}
      kwargs[:base_url] = provider_spec["base_url"] if params.include?(:base_url) &&
                                                       provider_spec["base_url"]
      if info[:api_key_required]
        key = api_keys[kind.to_sym] || api_keys[kind]
        raise Error, "api_keys[#{kind.inspect}] is required for provider #{kind}" if key.nil?

        kwargs[:api_key] = key
      end

      provider_klass.new(**kwargs)
    end

    def self.stream_provider_class(info)
      class_name = info[:stream_provider_class]
      return nil unless class_name

      Object.const_get(class_name)
    end

    def self.build_stream_provider_instance(stream_klass, kind, info, api_keys, provider_spec)
      return nil if stream_klass.nil?

      build_provider_instance(stream_klass, kind, info, api_keys, provider_spec)
    end

    def self.resolve_api_keys(api_keys)
      explicit = api_keys.each_with_object({}) do |(key, value), result|
        result[key.respond_to?(:to_sym) ? key.to_sym : key] = value
      end

      {
        anthropic: ENV.fetch("ANTHROPIC_API_KEY", nil),
        openai: ENV.fetch("OPENAI_API_KEY", nil),
        gemini: ENV.fetch("GEMINI_API_KEY", nil)
      }.merge(explicit)
    end

    def self.build_registry(tools_spec, tool_handlers:, args_key_style: :symbol)
      registry = Harnas::Tools::Registry.new

      tools_spec.each do |tool|
        validate_tool_descriptor_type!(tool)

        handler_name = tool["handler"]
        handler      = tool_handlers[handler_name] ||
                       (raise UnresolvedHandlerError,
                              "tool handler #{handler_name.inspect} not in tool_handlers")
        tool_args_key_style = normalize_args_key_style(
          tool.fetch("args_key_style", args_key_style)
        )

        registry.register(
          Harnas::Tools::Tool.new(
            name: tool["name"],
            description: tool["description"],
            input_schema: symbolize_schema(tool["input_schema"]),
            config: tool.fetch("config", {}),
            handler: handler_name,
            args_key_style: tool_args_key_style,
            &handler
          )
        )
      end

      registry
    end

    def self.validate_tool_descriptor_types!(tools)
      return unless tools.is_a?(Array)

      tools.each { |tool| validate_tool_descriptor_type!(tool) }
    end

    def self.validate_tool_descriptor_type!(tool)
      return if tool.is_a?(Hash)

      raise ArgumentError,
            "tools[] entries must be Hash descriptors, not #{tool.class} instances. " \
            "Pass callable handlers via tool_handlers: on Runtime.build — " \
            "e.g. Runtime.build(manifest: ..., tool_handlers: mcp.tool_handlers)"
    end

    def self.normalize_args_key_style(value)
      normalized = value.to_sym if value.respond_to?(:to_sym)
      return normalized if %i[symbol string].include?(normalized)

      raise ArgumentError, "args_key_style must be :symbol or :string"
    end

    def self.symbolize_schema(schema)
      case schema
      when Hash  then schema.each_with_object({}) { |(k, v), h| h[k.to_sym] = symbolize_schema(v) }
      when Array then schema.map { |v| symbolize_schema(v) }
      else            schema
      end
    end

    def self.manifest_snapshot(manifest)
      JSON.parse(JSON.generate(manifest))
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

        StrategyInstallation.new(
          klass: klass,
          config: config,
          on_error: strategy.fetch("on_error", "isolate"),
          name: name
        )
      end
    end

    def self.build_hooks(hooks_spec, hook_handlers:)
      hooks_spec.map do |hook|
        handler_name = hook.fetch("handler")
        handler = hook_handlers[handler_name] ||
                  (raise UnresolvedHandlerError,
                         "hook handler #{handler_name.inspect} not in hook_handlers")

        HookInstallation.new(
          point: hook.fetch("point").delete_prefix(":"),
          handler: handler,
          config: symbolize_config(hook.fetch("config", {})),
          on_error: hook.fetch("on_error", "isolate"),
          name: handler_name
        )
      end
    end

    def self.resolve_config(strategy_name, raw_config, strategy_handlers, provider_bundle)
      config = symbolize_config(raw_config)

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

    def self.symbolize_config(raw_config)
      raw_config.each_with_object({}) { |(k, v), h| h[k.to_sym] = v }
    end

    def self.raise_unresolved_strategy_handler(strategy_name, field, handler_name)
      raise UnresolvedHandlerError,
            "strategy handler #{handler_name.inspect} " \
            "(for #{strategy_name} #{field}) not in strategy_handlers"
    end
  end
end
