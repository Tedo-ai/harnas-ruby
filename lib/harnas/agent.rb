# frozen_string_literal: true

require "json"
require "harnas/manifest"
require "harnas/agent_loop"
require "harnas/events/user_message"
require "harnas/hooks"

module Harnas
  # One-line entry point for loading a manifest, installing its
  # strategies, and driving a conversation.
  #
  #   agent = Harnas::Agent.from_manifest("examples/01-hello-world/manifest.json")
  #   agent.chat("hello").text
  #   agent.chat("and again")       # the Log is preserved across calls
  #   agent.log                     # full append-only event log
  #
  # The façade wraps Manifest.load + AgentLoop for the
  # common case of "build a runnable agent from a manifest file." It
  # deliberately does not expose every primitive; users who need the
  # Projection, Ingestor, or hooks reach for Manifest.load directly.
  #
  # Strategies declared in the manifest are installed onto the Agent's
  # Session on #chat (first call) and kept installed for the lifetime
  # of the Agent. Calling #shutdown removes them.
  class Agent
    Response = Data.define(:text, :stop_reason, :usage, :log)

    attr_reader :name

    def self.from_manifest(source, api_keys: {}, tool_handlers: {}, # rubocop:disable Metrics/ParameterLists
                           strategy_handlers: {}, hook_handlers: {},
                           max_turns: AgentLoop::DEFAULT_MAX_TURNS, system: nil,
                           attachment_store: nil)
      source = override_system(source, system) unless system.nil?

      loaded = Manifest.load(
        source,
        api_keys: api_keys,
        tool_handlers: tool_handlers,
        strategy_handlers: strategy_handlers,
        hook_handlers: hook_handlers,
        attachment_store: attachment_store
      )
      new(loaded: loaded, max_turns: max_turns)
    end

    # Return a manifest Hash with `system` set to the given text,
    # regardless of the underlying source form (Hash / JSON / path).
    def self.override_system(source, system)
      base =
        case source
        when Hash   then source.dup
        when String then JSON.parse(File.exist?(source) ? File.read(source) : source)
        else             raise ArgumentError, "unsupported manifest source: #{source.class}"
        end
      base.merge("system" => system)
    end
    private_class_method :override_system

    def initialize(loaded:, max_turns: AgentLoop::DEFAULT_MAX_TURNS)
      @loaded    = loaded
      @name      = loaded.name
      @max_turns = max_turns
      @installed_handlers = nil
    end

    # Append a user message and drive the AgentLoop until the assistant
    # finishes (stop_reason != :tool_use or no pending tool calls). Returns
    # a Response value derived from the final :assistant_message.
    def chat(text)
      chat_payload(Events::UserMessage.new(text: text).to_h)
    end

    def chat_payload(payload)
      ensure_strategies_installed!
      append_user_payload(payload)

      AgentLoop.new(
        session: @loaded.session,
        projection: @loaded.projection,
        runner: @loaded.runner,
        provider: @loaded.provider,
        ingestor: @loaded.ingestor,
        provider_kind: @loaded.provider_kind,
        max_turns: @max_turns
      ).run

      build_response
    end

    # Append a user message and drive the streaming AgentLoop path,
    # yielding each delta Event as soon as it is appended to the Log.
    # Manifests without a streaming provider fall back to #chat.
    def stream(text, &)
      stream_payload(Events::UserMessage.new(text: text).to_h, &)
    end

    def stream_payload(payload, &block)
      return chat_payload(payload) unless @loaded.stream_provider

      ensure_strategies_installed!
      append_user_payload(payload)

      AgentLoop.new(
        session: @loaded.session,
        projection: @loaded.projection,
        runner: @loaded.runner,
        stream_provider: @loaded.stream_provider,
        provider_kind: @loaded.provider_kind,
        max_turns: @max_turns,
        on_stream_event: block
      ).run

      build_response
    end

    def log
      @loaded.session.log
    end

    def session
      @loaded.session
    end

    def registry
      @loaded.registry
    end

    # Override the live provider instance the façade will call on the
    # next #chat. Intended for deterministic demos and tests (swapping
    # a live provider for a ScriptedProvider or CannedProvider); real
    # deployments configure the provider via the manifest.
    def use_provider(provider)
      @loaded.instance_variable_set(:@provider, provider)
      self
    end

    def use_stream_provider(stream_provider)
      @loaded.instance_variable_set(:@stream_provider, stream_provider)
      self
    end

    def from_session(session)
      self.class.new(loaded: @loaded.with_session(session), max_turns: @max_turns)
    end

    # Uninstall every manifest-declared strategy. Safe to call repeatedly.
    def shutdown
      return if @installed_handlers.nil?

      @installed_handlers.each do |handler|
        @loaded.session.hooks.handlers.each_value { |list| list.delete(handler) }
      end
      @installed_handlers = nil
    end

    private

    def ensure_strategies_installed!
      return unless @installed_handlers.nil?

      @installed_handlers = @loaded.install_strategies!
    end

    def append_user_payload(payload)
      @loaded.session.log.append(
        type: :user_message,
        payload: payload
      )
    end

    def build_response
      last_assistant = @loaded.session.log.reverse_each.find do |e|
        e.type == :assistant_message
      end
      return Response.new(text: "", stop_reason: nil, usage: {}, log: log) if last_assistant.nil?

      payload = last_assistant.payload
      Response.new(
        text: payload[:text].to_s,
        stop_reason: payload[:stop_reason],
        usage: payload[:usage] || {},
        log: log
      )
    end
  end
end
