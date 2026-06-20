# frozen_string_literal: true

module Harnas
  module ProviderCarriers
    module_function

    def carrier(destination:, index:, kind:, wire:, canonical_refs: [])
      out = {
        carrier_destination: destination,
        index: index,
        kind: kind,
        wire: wire
      }
      out[:canonical_refs] = canonical_refs unless canonical_refs.empty?
      out
    end

    def wire(carriers, destination)
      Array(carriers).each do |raw|
        carrier = symbolize(raw)
        next unless carrier[:carrier_destination] == destination

        return deep_copy(carrier[:wire]) if carrier.key?(:wire)
      end
      nil
    end

    def wires(carriers, destination)
      value = wire(carriers, destination)
      value.is_a?(Array) ? value : nil
    end

    def part_wire(block, destination)
      value = wire(symbolize(block)[:provider_parts], destination)
      value.is_a?(Hash) ? symbolize(value) : nil
    end

    def deep_copy(value)
      case value
      when Hash
        value.to_h { |key, child| [key, deep_copy(child)] }
      when Array
        value.map { |child| deep_copy(child) }
      else
        value
      end
    end

    def symbolize(value)
      return value.transform_keys(&:to_sym) if value.respond_to?(:transform_keys)

      {}
    end
  end
end
