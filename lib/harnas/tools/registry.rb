# frozen_string_literal: true

module Harnas
  module Tools
    class DuplicateToolError < StandardError; end
    class UnknownToolError < StandardError; end

    # In-memory registry of Tools by name. A Session carries one
    # Registry; the Projection reads it to emit the provider-specific
    # tool list, and the Runner reads it to execute a :tool_use Event.
    class Registry
      def initialize
        @tools = {}
      end

      def register(tool)
        name = tool.name
        raise DuplicateToolError, "tool #{name.inspect} already registered" if @tools.key?(name)

        @tools[name] = tool
        tool
      end

      def [](name)
        @tools.fetch(name) do
          raise UnknownToolError, "no tool registered as #{name.inspect}"
        end
      end

      def include?(name)
        @tools.key?(name)
      end

      def names
        @tools.keys
      end

      def tools
        @tools.values
      end

      def size
        @tools.size
      end
    end
  end
end
