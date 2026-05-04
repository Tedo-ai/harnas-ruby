# frozen_string_literal: true

module Harnas
  # The Hooks intervention bus — the bidirectional complement to
  # Observation. See spec/14-hooks.md for the canonical hook point
  # vocabulary, return-value semantics, and composition rules.
  #
  # With no handlers registered, invoke returns an empty Array (R3).
  # Handler exceptions are isolated and never propagate into the
  # calling code path (R4); they're warned to STDERR when $VERBOSE is
  # set and reported through Observation as :hook_handler_failed.
  class Hooks
    class TurnFailed < StandardError; end

    attr_reader :handlers

    def self.fresh_registry
      Hash.new { |h, k| h[k] = [] }
    end

    def self.default
      @default ||= new
    end

    class << self
      # Backward-compatible process-global API. Prefer session.hooks.
      def on(...)
        default.on(...)
      end

      def off(...)
        default.off(...)
      end

      def reset!
        @default = new
      end

      def invoke(...)
        default.invoke(...)
      end

      def scoped(...)
        default.scoped(...)
      end

      def handlers
        default.handlers
      end
    end

    def initialize
      @handlers = self.class.fresh_registry
      @handler_metadata = {}
    end

    # Register a handler for a hook point. Handler is any callable
    # that accepts the keyword payload for that point.
    def on(point, handler = nil, on_error: :isolate, name: nil, source: :hook, &block)
      h = handler || block
      raise ArgumentError, "hook handler or block required" if h.nil?

      @handlers[point] << h
      @handler_metadata[h] = {
        on_error: on_error.to_sym,
        name: name || h.class.name || "anonymous",
        source: source
      }
      h
    end

    def off(point, handler)
      @handlers[point].delete(handler)
      @handler_metadata.delete(handler)
    end

    def reset!
      @handlers = self.class.fresh_registry
    end

    # Invoke all registered handlers for `point` in registration
    # order. Returns an Array of non-nil returns (R3). Handler
    # exceptions are isolated (R4).
    def invoke(point, **ctx)
      returns = []
      @handlers[point].each do |handler|
        r = handler.call(**ctx)
        returns << r unless r.nil?
      rescue StandardError => e
        handle_failure(point, handler, e, ctx)
      end
      returns
    end

    # Scoped registration: snapshots the handler registry, yields,
    # and restores on exit (even if the block raises). Useful for
    # tests and ad-hoc "try this handler just for this run" usage.
    def scoped
      saved = self.class.fresh_registry
      saved_metadata = @handler_metadata.dup
      @handlers.each_pair { |k, v| saved[k] = v.dup }
      yield
    ensure
      @handlers = saved
      @handler_metadata = saved_metadata
    end

    private

    def handle_failure(point, handler, error, ctx)
      warn "Hook handler raised for #{point}: #{error.class}: #{error.message}" if $VERBOSE
      metadata = @handler_metadata.fetch(handler, {})
      if defined?(Harnas::Observation)
        bus = ctx[:session].respond_to?(:observation) ? ctx[:session].observation : Harnas::Observation
        bus.emit(
          :hook_handler_failed,
          point: point,
          handler: metadata[:name] || handler.class.name || "anonymous",
          error: error
        )
      end
      fail_turn!(ctx.fetch(:session), metadata, error) if metadata[:on_error] == :fail_turn
    end

    def fail_turn!(session, metadata, error)
      require "harnas/events/runtime_error"

      session.log.append(
        type: :runtime_error,
        payload: Harnas::Events::RuntimeError.new(
          source: metadata[:source] || :hook,
          handler: metadata[:name] || "anonymous",
          error_class: error.class.name.to_s,
          message: error.message.to_s,
          terminal: true
        ).to_h
      )
      raise TurnFailed, "#{metadata[:name] || "hook"} failed: #{error.class}: #{error.message}"
    end
  end
end
