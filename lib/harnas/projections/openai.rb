# frozen_string_literal: true

require "json"
require "harnas/content_blocks"
require "harnas/log"
require "harnas/mutations"
require "harnas/observation"

module Harnas
  module Projections
    # Pure function: a Log of Events to an OpenAI Chat Completions API
    # request body. Mutation Events (:compact, :revert) are resolved
    # via Harnas::Mutations.apply before dispatch.
    #
    # Wire shape (relevant to tool use):
    #
    #   :user_message / :summary   -> { role: "user",      content: text }
    #   :assistant_message         -> { role: "assistant", content: text }
    #   :tool_use                  -> merged into the preceding assistant
    #                                 message as tool_calls[]
    #   :tool_result               -> { role: "tool", tool_call_id: id,
    #                                   content: output }
    #
    # An assistant turn that only emits tool_use (no text) becomes
    # `{ role: "assistant", content: null, tool_calls: [...] }`.
    class OpenAI
      def initialize(model:, registry: nil, system: nil, attachment_store: nil)
        @model    = model
        @registry = registry
        @system   = system
        @attachment_store = attachment_store
      end

      def call(log)
        effective = Mutations.apply(log)
        messages  = build_messages(effective)
        messages  = prepend_system(messages) if @system && !@system.empty?

        request = { model: @model, messages: messages }
        request[:tools] = tool_descriptors if @registry&.size&.positive?

        Observation.emit(
          :projection_invoked,
          projection: :openai,
          log_size: log.size,
          request: request
        )

        request
      end

      private

      def prepend_system(messages)
        [{ role: "system", content: @system }, *messages]
      end

      def build_messages(events)
        messages = []
        events.each { |evt| append_event(messages, evt) }
        messages
      end

      def append_event(messages, evt)
        case evt.type
        when :user_message, :summary
          messages << { role: "user", content: content(evt.payload) }
        when :assistant_message
          messages << { role: "assistant", content: content(evt.payload) }
        when :tool_use
          merge_tool_use(messages, evt)
        when :tool_result
          messages << {
            role: "tool",
            tool_call_id: evt.payload[:tool_use_id],
            content: evt.payload[:error] || evt.payload[:output].to_s
          }
        end
      end

      def content(payload)
        blocks = ContentBlocks.from_payload(payload)
        return blocks.first[:text].to_s if blocks.size == 1 && blocks.first[:type] == "text"

        blocks.map do |block|
          case block[:type]
          when "text"
            { type: "text", text: block[:text].to_s }
          when "image"
            { type: "image_url", image_url: { url: image_url(block) } }
          else
            raise ArgumentError, "unsupported OpenAI content block type: #{block[:type]}"
          end
        end
      end

      def image_url(block)
        source = ContentBlocks.symbolize(block[:source] || {})
        return source[:url].to_s if source[:kind] == "url"

        resolved = ContentBlocks.resolve_data(block, @attachment_store)
        "data:#{resolved[:media_type]};base64,#{resolved[:data]}"
      end

      # Fold :tool_use events into the preceding assistant message's
      # tool_calls array. If the preceding assistant message had empty
      # text, its content becomes null per OpenAI's convention for
      # tool-only assistant turns.
      def merge_tool_use(messages, evt)
        wire_tool_call = {
          id: evt.payload[:id],
          type: "function",
          function: {
            name: evt.payload[:name],
            arguments: JSON.generate(evt.payload[:arguments] || {})
          }
        }

        prev = messages.last
        if prev && prev[:role] == "assistant"
          prev[:tool_calls] ||= []
          prev[:tool_calls] << wire_tool_call
          prev[:content] = nil if prev[:content] == ""
        else
          messages << {
            role: "assistant", content: nil, tool_calls: [wire_tool_call]
          }
        end
      end

      def tool_descriptors
        @registry.tools.map do |t|
          {
            type: "function",
            function: {
              name: t.name,
              description: t.description,
              parameters: t.input_schema
            }
          }
        end
      end
    end
  end
end
