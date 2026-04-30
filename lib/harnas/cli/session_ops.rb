# frozen_string_literal: true

require "fileutils"
require "json"

require "harnas/log"
require "harnas/manifest"
require "harnas/session"
require "harnas/tools/builtin"

module Harnas
  class CLI
    # File-backed operator commands for persisted Sessions.
    module SessionOps
      EXIT_DIFFERENT = 3

      module_function

      def fork(session_path:, at_seq:, out:)
        session = Harnas::Session.load(session_path)
        forked = session.fork(at_seq: at_seq)
        FileUtils.mkdir_p(File.dirname(out)) unless File.dirname(out) == "."
        forked.save(out)

        "forked #{session.id} at seq #{at_seq} -> #{out} (#{forked.log.size} events)\n"
      end

      def diff(left_path:, right_path:)
        left = Harnas::Session.load(left_path)
        right = Harnas::Session.load(right_path)
        left_rows = comparable_rows(left)
        right_rows = comparable_rows(right)
        return match(left_rows.size) if left_rows == right_rows

        mismatch(left_rows, right_rows)
      end

      def project(session_path:, manifest:, from_seq:, to_seq:)
        session = Harnas::Session.load(session_path)
        loaded = Harnas::Manifest.load(
          manifest,
          api_keys: projection_api_keys,
          tool_handlers: projection_tool_handlers
        )
        request = loaded.projection.call(slice_log(session.log, from_seq, to_seq))
        "#{JSON.pretty_generate(request)}\n"
      end

      def comparable_rows(session)
        [
          {
            "session" => {
              "id" => session.id,
              "metadata" => normalize(session.metadata)
            }
          }
        ] + session.log.map { |event| comparable_event(event) }
      end

      def comparable_event(event)
        {
          "seq" => event.seq,
          "id" => event.id,
          "type" => event.type.to_s,
          "payload" => normalize(event.payload)
        }
      end

      def match(count)
        {
          status: EXIT_SUCCESS,
          text: "sessions match (#{count - 1} events)\n"
        }
      end

      def mismatch(left_rows, right_rows)
        index = first_mismatch_index(left_rows, right_rows)
        {
          status: EXIT_DIFFERENT,
          text: [
            "sessions differ at #{label(index)}",
            "left:  #{format_row(left_rows[index])}",
            "right: #{format_row(right_rows[index])}",
            ""
          ].join("\n")
        }
      end

      def first_mismatch_index(left_rows, right_rows)
        limit = [left_rows.size, right_rows.size].max
        (0...limit).find { |idx| left_rows[idx] != right_rows[idx] }
      end

      def label(index)
        index.zero? ? "session header" : "seq #{index - 1}"
      end

      def format_row(row)
        row.nil? ? "<missing>" : JSON.generate(row)
      end

      def slice_log(log, from_seq, to_seq)
        from_seq ||= 0
        to_seq ||= log.size - 1
        raise ArgumentError, "--from-seq must be non-negative" if from_seq.negative?
        raise ArgumentError, "--to-seq must be >= --from-seq" if to_seq < from_seq

        sliced = Harnas::Log.new
        log.each do |event|
          next if event.seq < from_seq || event.seq > to_seq

          sliced.send(
            :restore,
            seq: event.seq,
            id: event.id,
            type: event.type,
            payload: event.payload
          )
        end
        sliced
      end

      def projection_api_keys
        { anthropic: "projection-only", openai: "projection-only", gemini: "projection-only" }
      end

      def projection_tool_handlers
        handlers = Hash.new do |_known, name|
          ->(_args) { raise "projection-only tool #{name}" }
        end
        handlers.merge!(Harnas::Tools::Builtin.handlers)
        handlers
      end

      def normalize(value)
        case value
        when Hash
          value.each_with_object({}) { |(key, val), result| result[key.to_s] = normalize(val) }
        when Array
          value.map { |val| normalize(val) }
        when Symbol
          value.to_s
        else
          value
        end
      end
    end
  end
end
