# frozen_string_literal: true

require "harnas/log"
require "harnas/capabilities"
require "harnas/content_blocks"
require "harnas/mutations"
require "harnas/observation"

module Harnas
  module Projections
    # Pure function: a Log of Events to a Google Gemini generateContent
    # request body.
    #
    # Structural notes:
    #   - top-level key is `contents` (not `messages`)
    #   - each entry has `parts: [...]` (list of parts, not flat content)
    #   - the assistant role is `model` (not `assistant`)
    #   - tool calls arrive as `functionCall` parts on a model-role entry
    #   - tool results are `functionResponse` parts on a user-role entry
    #   - tool declarations go in a top-level `tools` array as
    #     `{ functionDeclarations: [ { name, description, parameters } ] }`
    #
    # The `model` field at the top of the request hash is consumed by
    # the Gemini provider to build the URL path, then stripped from
    # the wire body. Mutation Events are resolved via
    # Harnas::Mutations.apply; :summary events produced by compaction
    # render as user-role messages.
    class Gemini
      THOUGHT_SIGNATURE_KIND = "gemini.thought_signature"

      # `thinking_budget: 0` tells Gemini not to enter thinking mode;
      # `nil` omits the field entirely (model default applies); a
      # positive integer opts in. Even when Gemini does emit
      # thoughtSignatures, the Gemini ingestor + projection round-trip
      # them via :annotation events, so any setting is safe.
      def initialize(model:, registry: nil, system: nil, thinking_budget: 0, # rubocop:disable Metrics/ParameterLists
                     attachment_store: nil, provider_kind: "gemini", capabilities: {},
                     capability_mismatch_behavior: "metadata_fallback")
        @model           = model
        @registry        = registry
        @system          = system
        @thinking_budget = thinking_budget
        @attachment_store = attachment_store
        @provider_kind = provider_kind
        @capabilities = capabilities || {}
        @capability_mismatch_behavior = capability_mismatch_behavior
      end

      def call(log)
        events   = Mutations.apply(log)
        contents = build_contents(events)

        request = { model: @model, contents: contents }
        request[:systemInstruction] = system_instruction if @system && !@system.empty?
        request[:tools] = tool_descriptors if @registry&.size&.positive?
        request[:generationConfig] = generation_config unless @thinking_budget.nil?

        Observation.emit(
          :projection_invoked,
          projection: :gemini,
          log_size: log.size,
          request: request
        )

        request
      end

      private

      def system_instruction
        { parts: [{ text: @system }] }
      end

      def generation_config
        { thinkingConfig: { thinkingBudget: @thinking_budget } }
      end

      def build_contents(events)
        @tool_use_names = index_tool_use_names(events)
        contents = []
        events.each_with_index do |evt, idx|
          append_event(contents, evt, events[idx + 1])
        end
        contents
      end

      def index_tool_use_names(events)
        events.each_with_object({}) do |evt, acc|
          acc[evt.payload[:id]] = evt.payload[:name] if evt.type == :tool_use
        end
      end

      def append_event(contents, evt, next_evt = nil)
        case evt.type
        when :user_message, :summary
          contents << { role: "user", parts: parts(evt.payload) }
        when :assistant_message
          append_assistant_text(contents, evt)
        when :tool_use
          append_function_call(contents, evt, signature_from(next_evt))
        when :tool_result
          append_function_response(contents, evt)
        end
      end

      def signature_from(event)
        return nil unless event && event.type == :annotation
        return nil unless event.payload[:kind] == THOUGHT_SIGNATURE_KIND

        event.payload[:data][:signature]
      end

      def append_assistant_text(contents, evt)
        rendered = parts(evt.payload)
        return if rendered.empty?

        contents << { role: "model", parts: rendered }
      end

      def parts(payload)
        ContentBlocks.from_payload(payload).filter_map do |block|
          case block[:type]
          when "text"
            text = block[:text].to_s
            text.empty? ? nil : { text: text }
          when "image", "document"
            fallback = fallback_if_unsupported(block)
            next({ text: fallback[:text] }) if fallback

            resolved = ContentBlocks.resolve_data(block, @attachment_store)
            { inline_data: { mime_type: resolved[:media_type], data: resolved[:data] } }
          else
            raise ArgumentError, "unsupported Gemini content block type: #{block[:type]}"
          end
        end
      end

      def fallback_if_unsupported(block)
        block_type = block[:type]
        return nil if Capabilities.supported?(provider_kind: @provider_kind, model: @model,
                                              overrides: @capabilities, block_type: block_type)

        if Capabilities.mismatch_behavior(@capability_mismatch_behavior) == "error"
          raise CapabilityMismatchError.new(provider_kind: @provider_kind, model: @model,
                                            block_type: block_type)
        end

        Capabilities.fallback_block(block, @attachment_store)
      end

      # Tool calls merge into the trailing model entry if the previous
      # model entry has no text — otherwise create a new one. Gemini
      # tolerates model entries with only functionCall parts.
      def append_function_call(contents, evt, signature = nil)
        part = {
          functionCall: {
            name: evt.payload[:name],
            args: evt.payload[:arguments] || {}
          }
        }
        part[:thoughtSignature] = signature if signature

        prev = contents.last
        if prev && prev[:role] == "model"
          prev[:parts] << part
        else
          contents << { role: "model", parts: [part] }
        end
      end

      # Tool results are user-role entries with a functionResponse part.
      # Gemini expects `response` to be a dict; wrap the string output
      # under a `content` key for interoperability.
      #
      # `tool_use_id` is the canonical Log's correlation key; on the
      # wire Gemini wants the function `name` here, which we look up
      # from the matching :tool_use in the Log. Falls back to the id
      # itself if no match (shouldn't happen but stays defensive).
      def append_function_response(contents, evt)
        response = if evt.payload[:error]
                     { error: evt.payload[:error] }
                   else
                     { content: evt.payload[:output].to_s }
                   end

        tool_use_id = evt.payload[:tool_use_id]
        wire_name   = @tool_use_names[tool_use_id] || tool_use_id

        contents << {
          role: "user",
          parts: [{
            functionResponse: {
              name: wire_name,
              response: response
            }
          }]
        }
      end

      def tool_descriptors
        [
          {
            functionDeclarations: @registry.tools.map do |t|
              {
                name: t.name,
                description: t.description,
                parameters: t.input_schema
              }
            end
          }
        ]
      end
    end
  end
end
