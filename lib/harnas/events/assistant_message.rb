# frozen_string_literal: true

module Harnas
  module Events
    # Payload type for an :assistant_message Event. Carries the model's
    # text reply plus the neutral fields every provider returns under
    # different names — `stop_reason` (a normalized Symbol) and
    # `usage` (a Hash; the wire shape is provider-specific). Each
    # provider's Ingestor normalizes the wire response into this
    # shape.
    AssistantMessage = Data.define(:text, :stop_reason, :usage, :reasoning) do
      def initialize(text:, stop_reason:, usage: {}, reasoning: nil)
        allowed = %i[end_turn max_tokens tool_use stop_sequence refusal other]

        raise ArgumentError, "text must be a String"        unless text.is_a?(String)
        raise ArgumentError, "stop_reason must be a Symbol" unless stop_reason.is_a?(Symbol)
        unless allowed.include?(stop_reason)
          raise ArgumentError,
                "stop_reason must be one of #{allowed.inspect}, got #{stop_reason.inspect}"
        end
        raise ArgumentError, "usage must be a Hash" unless usage.is_a?(Hash)
        unless reasoning.nil? ||
               (reasoning.is_a?(Array) && reasoning.all? { |b| reasoning_block?(b) })
          raise ArgumentError, "reasoning must be an Array of text blocks"
        end

        super
      end

      def to_h
        out = { text: text, stop_reason: stop_reason, usage: usage }
        out[:reasoning] = reasoning unless reasoning.nil? || reasoning.empty?
        out
      end

      private

      def reasoning_block?(block)
        block.is_a?(Hash) &&
          (block[:type] || block["type"]) == "text" &&
          (block[:text] || block["text"]).is_a?(String) &&
          (!block.key?(:signature) || block[:signature].is_a?(String)) &&
          (!block.key?("signature") || block["signature"].is_a?(String))
      end
    end
  end
end
