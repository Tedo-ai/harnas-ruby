# frozen_string_literal: true

module Harnas
  module Events
    # Payload type for a :user_message Event. The Log stores its #to_h
    # as the Event's payload hash; Projections read evt.payload[:text].
    UserMessage = Data.define(:text) do
      def initialize(text:)
        raise ArgumentError, "text must be a String" unless text.is_a?(String)
        raise ArgumentError, "text must not be empty" if text.empty?

        super
      end
    end
  end
end
