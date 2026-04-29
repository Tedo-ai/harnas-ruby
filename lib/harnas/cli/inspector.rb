# frozen_string_literal: true

require "json"

module Harnas
  class CLI
    # Formats a persisted Session for operator inspection.
    class Inspector
      def initialize(session)
        @session = session
      end

      def to_h
        events = @session.log.to_a
        {
          session: {
            id: @session.id,
            metadata: @session.metadata,
            event_count: events.size,
            first_seq: events.first&.seq,
            last_seq: events.last&.seq
          },
          event_counts: event_counts(events),
          events: events.map { |event| inspect_event(event) }
        }
      end

      def to_text
        payload = to_h
        summary = payload.fetch(:session)
        lines = [
          "session #{summary.fetch(:id)}",
          "metadata #{JSON.generate(summary.fetch(:metadata))}",
          "events #{summary.fetch(:event_count)} " \
          "seq=#{summary.fetch(:first_seq).inspect}..#{summary.fetch(:last_seq).inspect}",
          "counts #{JSON.generate(payload.fetch(:event_counts))}",
          ""
        ]
        lines.concat(payload.fetch(:events).map { |event| format_event(event) })
        "#{lines.join("\n")}\n"
      end

      private

      def event_counts(events)
        events.each_with_object(Hash.new(0)) { |event, counts| counts[event.type.to_s] += 1 }
              .sort.to_h
      end

      def inspect_event(event)
        {
          seq: event.seq,
          type: event.type.to_s,
          summary: event_summary(event)
        }
      end

      def format_event(event)
        seq = event.fetch(:seq).to_s.rjust(4)
        type = event.fetch(:type).ljust(26)
        "#{seq}  #{type}  #{event.fetch(:summary)}"
      end

      def event_summary(event)
        payload = event.payload
        case event.type
        when :user_message, :assistant_message, :summary
          truncate(payload[:text])
        when :tool_use
          "#{payload[:name]} #{JSON.generate(payload[:arguments] || {})}"
        when :tool_result
          tool_result_summary(payload)
        when :provider_error
          "#{payload[:provider]} #{payload[:status] || "error"} #{payload[:message]}"
        when :compact
          "replaces=#{payload[:replaces].inspect} #{truncate(payload[:summary])}"
        when :revert
          "revokes=#{payload[:revokes]}"
        else
          truncate(JSON.generate(payload))
        end
      end

      def tool_result_summary(payload)
        if payload[:error]
          "error for #{payload[:tool_use_id]}: #{truncate(payload[:error])}"
        else
          "ok for #{payload[:tool_use_id]}: #{truncate(payload[:output])}"
        end
      end

      def truncate(value, limit = 96)
        text = value.to_s.gsub(/\s+/, " ").strip
        return text if text.length <= limit

        "#{text[0, limit - 1]}..."
      end
    end
  end
end
