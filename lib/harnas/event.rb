# frozen_string_literal: true

module Harnas
  Event = Data.define(:seq, :id, :type, :payload) do
    def initialize(seq:, id:, type:, payload:)
      raise ArgumentError, "seq must be an Integer" unless seq.is_a?(Integer)
      raise ArgumentError, "type must be a Symbol" unless type.is_a?(Symbol)
      raise ArgumentError, "payload must be a Hash" unless payload.is_a?(Hash)

      super
    end
  end
end
