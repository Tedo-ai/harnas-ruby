# frozen_string_literal: true

module Harnas
  class CapabilityMismatchError < StandardError
    attr_reader :block_type

    def initialize(provider_kind:, model:, block_type:)
      @block_type = block_type
      super("#{provider_kind}/#{model} does not support #{block_type} content blocks")
    end
  end

  module Capabilities
    module_function

    def supported?(provider_kind:, model:, overrides:, block_type:)
      key = "user_message_#{block_type}s"
      return overrides[key] unless overrides.nil? || !overrides.key?(key)

      images, documents = defaults(provider_kind.to_s, model.to_s.downcase)
      return images if block_type == "image"
      return documents if block_type == "document"

      true
    end

    def defaults(provider_kind, model)
      case provider_kind
      when "anthropic", "mock"
        return [false, false] if model.start_with?("claude-2-")
        return [true, true] if model.match?(/claude-3-[57]|claude-(sonnet|opus)-4/)
        return [true, false] if model.start_with?("claude-3-", "claude-")
      when "openai"
        return [true, false] if model.start_with?("gpt-4o") ||
                                %w[gpt-4-turbo gpt-4-vision-preview].include?(model)
      when "gemini"
        return [true, false] if model.start_with?("gemini-1.0-")
        return [true, true] if model.start_with?("gemini-1.5-", "gemini-2.0-",
                                                 "gemini-3.", "gemini-")
      end
      [false, false]
    end

    def mismatch_behavior(value)
      value == "error" ? "error" : "metadata_fallback"
    end

    def fallback_block(block, store)
      meta = ContentBlocks.resolve_data(block, store)
      { type: "text", text: fallback_text(block, meta) }
    end

    def fallback_text(block, meta)
      type = block[:type].to_s
      segments = [
        "[Note: A #{type} was attached to this message but cannot be viewed by this provider."
      ]
      segments << "Name: #{block[:name]}." if block[:name]
      media_type = block[:media_type] || meta[:media_type]
      segments << "Type: #{media_type}." if media_type
      segments << "Size: #{meta[:byte_size]} bytes." if meta[:byte_size].to_i.positive?
      segments << "URI: #{meta[:uri]}." if meta[:uri]
      segments << "Use available tools to access the content.]"
      segments.join(" ")
    end
  end
end
