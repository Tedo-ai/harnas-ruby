# frozen_string_literal: true

module Harnas
  # The Observation hook bus: a normative emission point for canonical
  # lifecycle events. See spec/13-observation.md for the contract,
  # the canonical event vocabulary, and forward-compatibility rules.
  #
  # With no Subscribers registered, `emit` is a no-op (R2). Subscriber
  # exceptions are isolated and never propagate into the calling code
  # path (R3); they're warned to STDERR when $VERBOSE is set, otherwise
  # silently swallowed.
  class Observation
    attr_reader :subscribers

    class << self
      def default
        @default ||= new
      end

      def current
        Thread.current[:harnas_observation] || default
      end

      def with_current(bus)
        previous = Thread.current[:harnas_observation]
        Thread.current[:harnas_observation] = bus
        yield
      ensure
        Thread.current[:harnas_observation] = previous
      end

      # Backward-compatible process-global API. Prefer session.observation.
      def subscribe(...)
        default.subscribe(...)
      end

      def unsubscribe(...)
        default.unsubscribe(...)
      end

      def reset!
        @default = new
      end

      def emit(...)
        current.emit(...)
      end

      def subscribed(...)
        default.subscribed(...)
      end

      def subscribers
        default.subscribers
      end
    end

    def initialize
      @subscribers = []
    end

    def subscribe(subscriber = nil, &block)
      sub = subscriber || block
      raise ArgumentError, "subscribe requires a subscriber or a block" if sub.nil?

      @subscribers << sub
      sub
    end

    def unsubscribe(sub)
      @subscribers.delete(sub)
    end

    def reset!
      @subscribers = []
    end

    def emit(event, **payload)
      return if @subscribers.empty?

      @subscribers.each do |sub|
        sub.call(event, payload)
      rescue StandardError => e
        warn "Observation subscriber raised: #{e.class}: #{e.message}" if $VERBOSE
      end
    end

    # Scoped subscription: registers a fresh Collector for the
    # duration of the block, yields it, and unsubscribes on exit
    # (even if the block raises).
    def subscribed
      collector = Collector.new
      sub = subscribe(collector)
      yield collector
    ensure
      unsubscribe(sub) if sub
    end

    # In-memory subscriber that records every event in order. Useful
    # for tests, benchmarking, and ad-hoc inspection.
    class Collector
      attr_reader :events

      def initialize
        @events = []
      end

      def call(event, payload)
        @events << [event, payload]
      end

      def of(event_name)
        @events.select { |(e, _)| e == event_name }
      end

      def count(event_name)
        of(event_name).size
      end

      def reset!
        @events = []
      end
    end
  end
end
