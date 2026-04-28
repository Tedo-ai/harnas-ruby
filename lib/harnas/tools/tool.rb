# frozen_string_literal: true

module Harnas
  module Tools
    # Minimal base for a registered Tool. A Tool is anything responding
    # to #name, #description, #input_schema (a JSON-Schema-shaped Hash),
    # and #call(arguments) returning a String (the tool's output).
    #
    # Subclass and override, or just construct any object with the same
    # four methods — the Registry does not require inheritance from this
    # class.
    class Tool
      attr_reader :name, :description, :input_schema

      def initialize(name:, description:, input_schema:, &block)
        raise ArgumentError, "name must be a non-empty String" \
          unless name.is_a?(String) && !name.empty?
        raise ArgumentError, "description must be a String"    unless description.is_a?(String)
        raise ArgumentError, "input_schema must be a Hash"     unless input_schema.is_a?(Hash)
        raise ArgumentError, "block required to implement #call" unless block

        @name         = name
        @description  = description
        @input_schema = input_schema
        @block        = block
      end

      def call(arguments)
        @block.call(arguments)
      end
    end
  end
end
