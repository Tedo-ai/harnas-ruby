# frozen_string_literal: true

require "digest"
require "json"

module Harnas
  module CapabilityManifest
    def self.ref(manifest)
      "cap_sha256_#{Digest::SHA256.hexdigest(canonical_json(manifest))}"
    end

    def self.canonical_json(value)
      JSON.generate(deep_sort(value))
    end
    private_class_method :canonical_json

    def self.deep_sort(value)
      case value
      when Hash
        value.keys.map(&:to_s).sort.to_h { |key| [key, deep_sort(value[key] || value[key.to_sym])] }
      when Array
        value.map { |item| deep_sort(item) }
      else
        value
      end
    end
    private_class_method :deep_sort

    class MemoryStore
      def initialize
        @items = {}
      end

      def put(manifest)
        manifest_ref = CapabilityManifest.ref(manifest)
        @items[manifest_ref] = manifest
        manifest_ref
      end

      def get(manifest_ref)
        @items[manifest_ref]
      end
    end
  end
end
