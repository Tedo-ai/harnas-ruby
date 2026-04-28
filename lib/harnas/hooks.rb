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
  module Hooks
    class << self
      attr_reader :handlers

      def fresh_registry
        Hash.new { |h, k| h[k] = [] }
      end

      # Register a handler for a hook point. Handler is any callable
      # that accepts the keyword payload for that point.
      def on(point, handler = nil, &block)
        h = handler || block
        raise ArgumentError, "hook handler or block required" if h.nil?

        @handlers[point] << h
        h
      end

      def off(point, handler)
        @handlers[point].delete(handler)
      end

      def reset!
        @handlers = fresh_registry
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
          handle_failure(point, handler, e)
        end
        returns
      end

      # Scoped registration: snapshots the handler registry, yields,
      # and restores on exit (even if the block raises). Useful for
      # tests and ad-hoc "try this handler just for this run" usage.
      def scoped
        saved = fresh_registry
        @handlers.each_pair { |k, v| saved[k] = v.dup }
        yield
      ensure
        @handlers = saved
      end

      private

      def handle_failure(point, handler, error)
        warn "Hook handler raised for #{point}: #{error.class}: #{error.message}" if $VERBOSE
        return unless defined?(Harnas::Observation)

        Harnas::Observation.emit(
          :hook_handler_failed,
          point: point,
          handler: handler.class.name || "anonymous",
          error: error
        )
      end
    end

    reset!
  end
end
