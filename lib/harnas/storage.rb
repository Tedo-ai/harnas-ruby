# frozen_string_literal: true

require "json"
require "harnas/event"
require "harnas/session"

module Harnas
  module Storage
    CONFLICT_REASON = "storage_conflict"

    EventDraft = Data.define(:id, :timestamp, :type, :payload)
    EventRow = Data.define(:seq, :id, :timestamp, :type, :payload, :content_hash)
    SessionHeader = Data.define(:id, :metadata, :parent_session_id,
                                :root_session_id, :spawn_id,
                                :spawned_by_event_id, :delegation_chain)

    class ConflictError < StandardError
      attr_reader :reason, :current_next_seq

      def initialize(expected_next_seq:, current_next_seq:)
        @reason = CONFLICT_REASON
        @current_next_seq = current_next_seq
        super(
          "#{CONFLICT_REASON}: expected next seq #{expected_next_seq}, " \
          "current next seq #{current_next_seq}"
        )
      end
    end

    class MemoryAdapter
      def initialize(header: nil, events: [])
        @header = header
        @events = events.dup
      end

      def load_session
        @header
      end

      def save_header(header)
        @header = header
        nil
      end

      def append_event(draft, expected_next_seq: nil)
        check_expected!(expected_next_seq)
        row = EventRow.new(seq: @events.size, id: draft.id,
                           timestamp: draft.timestamp, type: draft.type,
                           payload: Storage.deep_copy(draft.payload), content_hash: nil)
        @events << row
        row
      end

      def events_since(cursor)
        start = cursor.nil? ? 0 : cursor + 1
        @events.drop(start)
      end

      private

      def check_expected!(expected_next_seq)
        return if expected_next_seq.nil? || expected_next_seq == @events.size

        raise ConflictError.new(expected_next_seq: expected_next_seq,
                                current_next_seq: @events.size)
      end
    end

    class FileAdapter
      def initialize(path, header: nil)
        @path = path
        @initial_header = header
      end

      def load_session
        return @initial_header unless File.exist?(@path)

        header, = read_all
        header
      end

      def save_header(header)
        _, rows = readable? ? read_all : [nil, []]
        write_all(header, rows)
      end

      def append_event(draft, expected_next_seq: nil)
        header, rows = readable? ? read_all : [@initial_header, []]
        if !expected_next_seq.nil? && expected_next_seq != rows.size
          raise ConflictError.new(expected_next_seq: expected_next_seq,
                                  current_next_seq: rows.size)
        end
        row = EventRow.new(seq: rows.size, id: draft.id, timestamp: draft.timestamp,
                           type: draft.type, payload: Storage.deep_copy(draft.payload),
                           content_hash: nil)
        write_all(header, rows + [row])
        row
      end

      def events_since(cursor)
        return [] unless readable?

        _, rows = read_all
        rows.drop(cursor.nil? ? 0 : cursor + 1)
      end

      private

      def readable?
        File.exist?(@path) && !File.empty?(@path)
      end

      def read_all
        rows = File.readlines(@path, chomp: true).reject(&:empty?).map { |line| JSON.parse(line) }
        raise ArgumentError, "session file is empty" if rows.empty?
        raise ArgumentError, "missing session header" unless rows.first[Harnas::SESSION_HEADER_KEY]

        [header_from_hash(rows.first), rows.drop(1).each_with_index.map do |row, idx|
          row_from_hash(row, idx)
        end]
      end

      def write_all(header, rows)
        File.open(@path, "w") do |io|
          io.puts JSON.generate(header_to_hash(header)) if header
          rows.each { |row| io.puts JSON.generate(row_to_hash(row)) }
        end
      end

      def header_from_hash(row)
        SessionHeader.new(id: row.fetch("id"), metadata: row.fetch("metadata", {}),
                          parent_session_id: row["parent_session_id"],
                          root_session_id: row["root_session_id"],
                          spawn_id: row["spawn_id"],
                          spawned_by_event_id: row["spawned_by_event_id"],
                          delegation_chain: row.fetch("delegation_chain", []))
      end

      def row_from_hash(row, expected_seq)
        unless row.fetch("seq") == expected_seq
          message = "invalid event seq at row #{expected_seq}: " \
                    "got #{row.fetch("seq")}, want #{expected_seq}"
          raise ArgumentError,
                message
        end

        EventRow.new(seq: row.fetch("seq"), id: row.fetch("id"),
                     timestamp: row["timestamp"], type: row.fetch("type").to_sym,
                     payload: row.fetch("payload"), content_hash: row["content_hash"])
      end

      def header_to_hash(header)
        {
          Harnas::SESSION_HEADER_KEY => true,
          "id" => header.id,
          "metadata" => header.metadata
        }.tap do |out|
          out["parent_session_id"] = header.parent_session_id if header.parent_session_id
          out["root_session_id"] = header.root_session_id if header.root_session_id
          out["spawn_id"] = header.spawn_id if header.spawn_id
          out["spawned_by_event_id"] = header.spawned_by_event_id if header.spawned_by_event_id
          out["delegation_chain"] = header.delegation_chain unless header.delegation_chain.empty?
        end
      end

      def row_to_hash(row)
        {
          "seq" => row.seq,
          "id" => row.id,
          "timestamp" => row.timestamp,
          "type" => row.type.to_s,
          "payload" => row.payload
        }.tap { |out| out["content_hash"] = row.content_hash if row.content_hash }
      end
    end

    def self.deep_copy(value)
      JSON.parse(JSON.generate(value))
    end
  end
end
