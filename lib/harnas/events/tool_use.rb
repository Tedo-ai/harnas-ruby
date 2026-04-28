# frozen_string_literal: true

module Harnas
  module Events
    # Payload type for a :tool_use Event.
    #
    # The assistant has requested that the harness execute a tool. The
    # `id` is a provider-assigned correlation handle that later
    # :tool_result Events reference via `tool_use_id`. The `name`
    # identifies which registered tool; `arguments` is the
    # (already-parsed) input the model wants the tool called with.
    ToolUse = Data.define(:id, :name, :arguments) do
      def initialize(id:, name:, arguments:)
        raise ArgumentError, "id must be a String"        unless id.is_a?(String)
        raise ArgumentError, "id must not be empty"       if id.empty?
        raise ArgumentError, "name must be a String"      unless name.is_a?(String)
        raise ArgumentError, "name must not be empty"     if name.empty?
        raise ArgumentError, "arguments must be a Hash"   unless arguments.is_a?(Hash)

        super
      end
    end
  end
end
