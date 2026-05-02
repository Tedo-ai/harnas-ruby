# frozen_string_literal: true

require "harnas/events/annotation"
require "harnas/events/assistant_message"
require "harnas/events/tool_use"
require "harnas/observation"

module Harnas
  module Ingestors
    # Pure function: a Gemini generateContent wire response to an
    # Array of Event-args Hashes the caller should append to its Log.
    #
    # Produces:
    #   - one :assistant_message event carrying the concatenated text
    #     parts (empty string when the model only emitted functionCall
    #     parts), the normalized stop_reason, and the normalized usage
    #   - zero or more :tool_use events, one per functionCall part,
    #     in wire order
    #
    # Gemini's wire shape has no explicit tool-call id — the wire
    # correlation key is the function `name`. To stay correct under
    # repeated calls to the same function, the ingestor synthesizes
    # a unique `id` per :tool_use (collision-free across turns) and
    # the Gemini projection looks up the function name via the Log
    # when emitting the functionResponse on the wire.
    class Gemini
      FINISH_REASON_MAP = {
        "STOP" => :end_turn,
        "MAX_TOKENS" => :max_tokens,
        "SAFETY" => :refusal,
        "RECITATION" => :refusal,
        "OTHER" => :other
      }.freeze

      THOUGHT_SIGNATURE_KIND = "gemini.thought_signature"

      def initialize
        @tool_call_counter = 0
      end

      def call(response)
        candidate = response.dig("candidates", 0)
        raise ArgumentError, "response has no candidates" if candidate.nil?

        parts = Array(candidate.dig("content", "parts"))
        stop  = resolve_stop_reason(candidate["finishReason"], parts)
        usage = normalize_usage(response["usageMetadata"] || {})

        events = [assistant_event(parts, stop, usage)]
        parts.each do |part|
          next unless part["functionCall"]

          events << tool_use_event(part["functionCall"])
          signature = part["thoughtSignature"]
          events << signature_annotation(part["functionCall"]["name"], signature) if signature
        end

        emit_tokens_consumed(usage)
        events
      end

      private

      def assistant_event(parts, stop, usage)
        text = parts.map { |p| p["text"].to_s }.join
        reasoning = reasoning_blocks(parts)
        {
          type: :assistant_message,
          payload: Events::AssistantMessage.new(
            text: text, stop_reason: stop, usage: usage, reasoning: reasoning
          ).to_h
        }
      end

      def reasoning_blocks(parts)
        blocks = parts.filter_map do |part|
          thought = part["thought"] || part["thoughtSummary"] || part["thought_summary"]
          next unless thought.is_a?(String) && !thought.empty?

          { type: "text", text: thought }
        end
        blocks.empty? ? nil : blocks
      end

      def tool_use_event(call)
        name = call["name"].to_s
        args = (call["args"] || {}).transform_keys(&:to_sym)
        {
          type: :tool_use,
          payload: Events::ToolUse.new(
            id: synthesize_id(name), name: name, arguments: args
          ).to_h
        }
      end

      # Gemini provides no id on functionCall parts. We need one that's
      # unique across turns (so repeated calls to the same function
      # don't collide on the Log's `tool_use_id` correlation), so we
      # mint a deterministic per-ingestor counter. Two implementations
      # using the same scheme on the same response sequence produce
      # byte-identical Logs, which conformance fixtures depend on.
      def synthesize_id(name)
        id = "gemini.#{name}.#{@tool_call_counter}"
        @tool_call_counter += 1
        id
      end

      # Side-car annotation emitted right after the matching :tool_use
      # so the Gemini projection can re-attach the signature to the
      # next request's functionCall part. The annotation references
      # the call by name; the projection looks for it as the event
      # immediately following the :tool_use it describes.
      def signature_annotation(name, signature)
        {
          type: :annotation,
          payload: Events::Annotation.new(
            kind: THOUGHT_SIGNATURE_KIND,
            data: { name: name, signature: signature }
          ).to_h
        }
      end

      # If any part is a functionCall, the turn is semantically a
      # tool-use turn regardless of what Gemini reports as finishReason.
      def resolve_stop_reason(wire_finish, parts)
        return :tool_use if parts.any? { |p| p["functionCall"] }

        FINISH_REASON_MAP.fetch(wire_finish, :other)
      end

      def normalize_usage(wire_usage)
        {
          input_tokens: wire_usage["promptTokenCount"] || 0,
          output_tokens: wire_usage["candidatesTokenCount"] || 0
        }
      end

      def emit_tokens_consumed(usage)
        Observation.emit(
          :tokens_consumed,
          provider: :gemini,
          input_tokens: usage[:input_tokens],
          output_tokens: usage[:output_tokens]
        )
      end
    end
  end
end
