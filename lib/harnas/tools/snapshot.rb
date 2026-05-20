# frozen_string_literal: true

require "json"

module Harnas
  module Tools
    # Helpers for snapshotting a registry's public tool descriptors into
    # session metadata or downstream manifests.
    module Snapshot
      def self.descriptors(registry)
        registry.tools.map do |tool|
          descriptor = {
            "name" => tool.name,
            "handler" => tool.respond_to?(:handler) && tool.handler ? tool.handler : tool.name,
            "description" => tool.description,
            "input_schema" => deep_json_copy(tool.input_schema),
            "config" => deep_json_copy(tool.respond_to?(:config) ? tool.config : {})
          }
          if tool.respond_to?(:args_key_style)
            descriptor["args_key_style"] = tool.args_key_style.to_s
          end
          descriptor
        end
      end

      def self.manifest_metadata(registry:, skills: nil, mcp: nil)
        metadata = { "tools" => descriptors(registry) }
        metadata["skills"] = deep_json_copy(skills) unless skills.nil?
        metadata["mcp"] = deep_json_copy(mcp) unless mcp.nil?
        metadata
      end

      def self.deep_json_copy(value)
        JSON.parse(JSON.generate(value))
      end
      private_class_method :deep_json_copy
    end
  end
end
