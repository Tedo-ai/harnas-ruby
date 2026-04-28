# frozen_string_literal: true

module Harnas
  module Events
    # Payload for :assistant_text_delta — one chunk of streamed
    # assistant text. Multiple such events within a single turn
    # concatenate into the turn's final text.
    AssistantTextDelta = Data.define(:turn_id, :chunk) do
      def initialize(turn_id:, chunk:)
        raise ArgumentError, "turn_id must be a String"  unless turn_id.is_a?(String)
        raise ArgumentError, "turn_id must not be empty" if turn_id.empty?
        raise ArgumentError, "chunk must be a String"    unless chunk.is_a?(String)

        super
      end
    end
  end
end
