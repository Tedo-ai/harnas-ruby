# frozen_string_literal: true

require "base64"

module Harnas
  module MCP
    module Content
      def self.flatten(content_items)
        Array(content_items).map { |item| flatten_item(item) }.join("\n\n")
      end

      def self.flatten_item(item)
        item = item.transform_keys(&:to_s) if item.respond_to?(:transform_keys)
        case item && item["type"]
        when "text"
          item["text"].to_s
        when "image"
          "[image: #{item["mimeType"]}, #{decoded_size(item["data"])} bytes]"
        when "resource", "resource_link"
          "[resource: #{item["uri"] || item.dig("resource", "uri")}]"
        else
          "[#{item && item["type"]}]"
        end
      end
      private_class_method :flatten_item

      def self.decoded_size(data)
        Base64.strict_decode64(data.to_s).bytesize
      rescue ArgumentError
        data.to_s.bytesize
      end
      private_class_method :decoded_size
    end
  end
end
