# frozen_string_literal: true

require "harnas/log"
require "harnas/mutations"
require "harnas/observation"

module Harnas
  module Projections
    # Pure function: a Log of Events to an Anthropic Messages API
    # request body. Mutation Events are resolved via Mutations.apply
    # before dispatch. Adjacent events by the same role collapse into
    # a single wire message carrying a content array:
    #
    #   :user_message / :summary / :tool_result  -> role: "user"
    #   :assistant_message / :tool_use           -> role: "assistant"
    #
    # When a group has exactly one text block, the content field uses
    # the legacy plain-string form so simple wire bodies stay simple
    # (and recorded text-only fixtures continue to match byte-for-byte).
    class Anthropic
      DEFAULT_MAX_TOKENS = 1024

      def initialize(model:, max_tokens: DEFAULT_MAX_TOKENS, registry: nil, system: nil)
        @model      = model
        @max_tokens = max_tokens
        @registry   = registry
        @system     = system
      end

      def call(log)
        effective = Mutations.apply(log)
        messages  = group_messages(effective)

        request = { model: @model, max_tokens: @max_tokens, messages: messages }
        request[:system] = @system if @system && !@system.empty?
        request[:tools] = tool_descriptors if @registry&.size&.positive?

        Observation.emit(
          :projection_invoked,
          projection: :anthropic,
          log_size: log.size,
          request: request
        )

        request
      end

      private

      def group_messages(events)
        groups = []
        current = nil

        events.each do |evt|
          translated = translate(evt)
          next if translated.nil?

          role, block = translated
          blocks = block.is_a?(Array) ? block : [block]
          if current && current[:role] == role
            current[:blocks].concat(blocks)
          else
            groups << current if current
            current = { role: role, blocks: blocks }
          end
        end
        groups << current if current

        groups.map { |g| finalize(g[:role], g[:blocks]) }
      end

      def finalize(role, blocks)
        content = blocks.size == 1 && blocks.first[:type] == "text" ? blocks.first[:text] : blocks
        { role: role, content: content }
      end

      def translate(evt)
        case evt.type
        when :user_message, :summary
          ["user", { type: "text", text: evt.payload[:text] }]
        when :assistant_message
          translate_assistant_text(evt)
        when :tool_use
          ["assistant", {
            type: "tool_use",
            id: evt.payload[:id],
            name: evt.payload[:name],
            input: evt.payload[:arguments]
          }]
        when :tool_result
          translate_tool_result(evt)
        end
      end

      def translate_assistant_text(evt)
        blocks = reasoning_blocks(evt)
        text = evt.payload[:text].to_s
        blocks << { type: "text", text: text } unless text.empty?
        return nil if blocks.empty?

        ["assistant", blocks]
      end

      def reasoning_blocks(evt)
        Array(evt.payload[:reasoning]).filter_map do |block|
          next unless (block[:type] || block["type"]) == "text"

          text = block[:text] || block["text"]
          next unless text.is_a?(String)

          out = { type: "thinking", thinking: text }
          signature = block[:signature] || block["signature"]
          out[:signature] = signature if signature
          out
        end
      end

      def translate_tool_result(evt)
        block = {
          type: "tool_result",
          tool_use_id: evt.payload[:tool_use_id]
        }
        if evt.payload[:error]
          block[:content]  = evt.payload[:error]
          block[:is_error] = true
        else
          block[:content] = evt.payload[:output]
        end
        ["user", block]
      end

      def tool_descriptors
        @registry.tools.map do |t|
          { name: t.name, description: t.description, input_schema: t.input_schema }
        end
      end
    end
  end
end
