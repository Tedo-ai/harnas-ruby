# frozen_string_literal: true

module Harnas
  # UI-neutral projection from a Log to transcript items.
  #
  # The transcript is intentionally semantic rather than visual: apps can
  # render bubbles, rows, cards, or timelines from the same item stream.
  module Transcript
    def self.project(log, include_tools: true, include_errors: true,
                     include_annotations: false)
      log.each.filter_map do |event|
        build_item(event, include_tools:, include_errors:, include_annotations:)
      end
    end

    def self.build_item(event, include_tools:, include_errors:, include_annotations:)
      return message_item(event) if %i[user_message assistant_message].include?(event.type)
      return tool_item(event) if include_tools && %i[tool_use tool_result].include?(event.type)
      return error_item(event) if include_errors && error_event?(event)
      return annotation_item(event) if include_annotations && event.type == :annotation
      return item(event, kind: event.type.to_s, payload: event.payload) if mutation_item?(event)

      nil
    end
    private_class_method :build_item

    def self.message_item(event)
      if event.type == :user_message
        return item(event, kind: "user", role: "user", text: event.payload[:text].to_s)
      end

      item(event,
           kind: "assistant",
           role: "assistant",
           text: event.payload[:text].to_s,
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
