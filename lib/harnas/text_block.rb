# frozen_string_literal: true

module Harnas
  TextBlock = Data.define(:text) do
    def initialize(text:)
      raise ArgumentError, "text must be a String" unless text.is_a?(String)
      raise ArgumentError, "text must not be empty" if text.empty?

      super
    end
  end
end
