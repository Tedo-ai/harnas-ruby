# frozen_string_literal: true

require "base64"

module Harnas
  # UI-neutral projection from a Log to transcript items.
  #
  # The transcript is intentionally semantic rather than visual: apps can
  # render bubbles, rows, cards, or timelines from the same item stream.
  module Transcript
    def self.project(log, include_tools: true, include_errors: true,
                     include_annotations: false, content_placeholder: nil)
      log.each.filter_map do |event|
        build_item(event, include_tools:, include_errors:, include_annotations:,
                          content_placeholder:)
      end
    end

    def self.build_item(event, include_tools:, include_errors:, include_annotations:,
                        content_placeholder:)
      if %i[user_message assistant_message].include?(event.type)
        return message_item(event, content_placeholder:)
      end
      return tool_item(event) if include_tools && %i[tool_use tool_result].include?(event.type)
      return error_item(event) if include_errors && error_event?(event)
      return annotation_item(event) if include_annotations && event.type == :annotation
      return item(event, kind: event.type.to_s, payload: event.payload) if mutation_item?(event)

      nil
    end
    private_class_method :build_item

    def self.message_item(event, content_placeholder:)
      if event.type == :user_message
        return item(event, kind: "user", role: "user",
                           text: message_text(event.payload, content_placeholder:))
      end

      item(event,
           kind: "assistant",
           role: "assistant",
           text: message_text(event.payload, content_placeholder:),
           stop_reason: event.payload[:stop_reason],
           usage: event.payload[:usage] || {},
           reasoning: event.payload[:reasoning])
    end
    private_class_method :message_item

    def self.tool_item(event)
      if event.type == :tool_use
        return item(event,
                    kind: "tool_use",
                    name: event.payload[:name],
                    tool_use_id: event.payload[:id],
                    arguments: event.payload[:arguments] || {})
      end

      item(event,
           kind: "tool_result",
           tool_use_id: event.payload[:tool_use_id],
           output: event.payload[:output],
           error: event.payload[:error],
           status: event.payload[:error] ? "error" : "ok")
    end
    private_class_method :tool_item

    def self.error_item(event)
      item(event,
           kind: event.type.to_s.delete_prefix(":"),
           error: event.payload[:message] || event.payload[:error],
           terminal: event.payload[:terminal],
           payload: event.payload)
    end
    private_class_method :error_item

    def self.annotation_item(event)
      item(event,
           kind: "annotation",
           annotation_kind: event.payload[:kind],
           data: event.payload[:data])
    end
    private_class_method :annotation_item

    def self.mutation_item?(event)
      %i[compact summary revert fork].include?(event.type)
    end
    private_class_method :mutation_item?

    def self.error_event?(event)
      %i[provider_error runtime_error].include?(event.type)
    end
    private_class_method :error_event?

    def self.message_text(payload, content_placeholder:)
      blocks = payload[:content] || payload["content"]
      return payload[:text].to_s if blocks.nil?

      Array(blocks).map do |block|
        if block[:type] == "text" || block["type"] == "text"
          block[:text] || block["text"] || ""
        else
          content_placeholder&.call(block) || default_content_placeholder(block)
        end
      end.join("\n")
    end
    private_class_method :message_text

    def self.default_content_placeholder(block)
      type = block[:type] || block["type"]
      media_type = block[:media_type] || block["media_type"]
      name = block[:name] || block["name"]
      size = content_block_size(block)
      parts = [type]
      parts << name unless name.to_s.empty?
      parts << media_type unless media_type.to_s.empty?
      parts << format_byte_size(size) if size.positive?
      "[#{parts.join(": ")}]"
    end
    private_class_method :default_content_placeholder

    def self.content_block_size(block)
      size = (block[:byte_size] || block["byte_size"]).to_i
      return size if size.positive?

      source = block[:source] || block["source"] || {}
      return 0 unless (source[:kind] || source["kind"]) == "base64"

      Base64.strict_decode64(source[:data] || source["data"]).bytesize
    rescue ArgumentError
      0
    end
    private_class_method :content_block_size

    def self.format_byte_size(size)
      return "#{(size + 1023) / 1024}kb" if size >= 1024

      "#{size} bytes"
    end
    private_class_method :format_byte_size

    def self.item(event, fields)
      {
        seq: event.seq,
        id: event.id,
        type: event.type.to_s
      }.merge(fields)
    end
    private_class_method :item
  end
end
