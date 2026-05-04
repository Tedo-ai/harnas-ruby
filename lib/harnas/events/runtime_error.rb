# frozen_string_literal: true

module Harnas
  module Events
    # Payload type for a :runtime_error Event — captures a harness-internal
    # failure such as a hook or strategy invocation aborting a turn.
    RuntimeError = Data.define(:source, :handler, :error_class, :message,
                               :terminal) do
      def initialize(source:, handler:, error_class:, message:, terminal:)
        raise ArgumentError, "source must be a Symbol or String" \
          unless source.is_a?(Symbol) || source.is_a?(String)
        raise ArgumentError, "handler must be a String" unless handler.is_a?(String)
        raise ArgumentError, "handler must not be empty" if handler.empty?
        raise ArgumentError, "error_class must be a String" unless error_class.is_a?(String)
        raise ArgumentError, "message must be a String" unless message.is_a?(String)
        raise ArgumentError, "terminal must be true or false" \
          unless [true, false].include?(terminal)

        super(source: source.to_s, handler: handler, error_class: error_class,
              message: message, terminal: terminal)
      end

      def to_h
        {
          source: source,
          handler: handler,
          error_class: error_class,
          message: message,
          terminal: terminal
        }
      end
    end
  end
end
