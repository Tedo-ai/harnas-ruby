# frozen_string_literal: true

module Harnas
  module Events
    # Payload type for an :assistant_message Event. Carries the model's
    # text reply plus the neutral fields every provider returns under
    # different names — `stop_reason` (a normalized Symbol) and
    # `usage` (a Hash; the wire shape is provider-specific). Each
    # provider's Ingestor normalizes the wire response into this
    # shape.
    AssistantMessage = Data.define(:text, :stop_reason, :usage) do
      def initialize(text:, stop_reason:, usage: {})
        allowed = %i[end_turn max_tokens tool_use stop_sequence refusal other]

        raise ArgumentError, "text must be a String"        unless text.is_a?(String)
        raise ArgumentError, "stop_reason must be a Symbol" unless stop_reason.is_a?(Symbol)
        unless allowed.include?(stop_reason)
          raise ArgumentError,
                "stop_reason must be one of #{allowed.inspect}, got #{stop_reason.inspect}"
        end
        raise ArgumentError, "usage must be a Hash" unless usage.is_a?(Hash)

        super
      end
    end
  end
end
