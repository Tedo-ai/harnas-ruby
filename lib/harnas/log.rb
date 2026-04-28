# frozen_string_literal: true

require "digest"
require "json"
require "harnas/event"
require "harnas/observation"

module Harnas
  class Log
    include Enumerable

    # Per-event-type payload fields whose value is a Ruby Symbol in
    # memory but serializes as a String in JSON. The load path
    # re-symbolizes these fields after JSON parsing so that the
    # resulting Log is structurally indistinguishable from one built
    # in memory.
    PAYLOAD_SYMBOL_FIELDS = {
      assistant_message: %i[stop_reason]
    }.freeze

    attr_accessor :observation

    def initialize(observation: nil)
      @events = []
      @observation = observation
    end

    def size
      @events.size
    end

    def each(&)
      @events.each(&)
    end

    def at(seq)
      @events[seq]
    end

    def since(seq)
      @events.drop(seq + 1)
    end

    def append(type:, payload:)
      seq    = @events.size
      digest = Digest::SHA256.hexdigest(JSON.generate(payload))[0, 12]
      id     = "evt_#{seq}_#{digest}"
      event  = Event.new(seq: seq, id: id, type: type, payload: payload)
      @events << event
      (@observation || Observation).emit(:event_appended, event: event, log_size: @events.size)
      event
    end

    # Serialize the Log to a JSONL stream — one JSON object per event,
    # in seq order. The stream can be a Pathname, a String path, or
    # an open IO. Returns self.
    def save(destination)
      with_write_io(destination) do |io|
        @events.each do |event|
          io.puts JSON.generate(
            seq: event.seq,
            id: event.id,
            type: event.type.to_s,
            payload: event.payload
          )
        end
      end
      self
    end

    # Read a JSONL stream written by #save and return a new Log with
    # the events restored verbatim (same seq, id, type, payload).
    # Events are NOT re-stamped: an event loaded with id "evt_3_abc"
    # keeps that id.
    def self.load(source)
      log = new
      with_read_io(source) do |io|
        io.each_line do |line|
          trimmed = line.strip
          next if trimmed.empty?

          log.send(:restore, JSON.parse(trimmed, symbolize_names: true))
        end
      end
      log
    end

    def self.with_read_io(source, &block)
      if io_like?(source)
        block.call(source)
      else
        File.open(source.to_s, "r", &block)
      end
    end
    private_class_method :with_read_io

    # Treat IO / StringIO / anything with a #read AND #each_line as an
    # already-opened stream; everything else (String path, Pathname) as
    # a filesystem path. A plain String has #each_line but no #read,
    # which is how we avoid opening a path string as a stream.
    def self.io_like?(source)
      source.respond_to?(:each_line) && source.respond_to?(:read) &&
        !source.is_a?(String)
    end
    private_class_method :io_like?

    private

    def with_write_io(destination, &block)
      if destination.respond_to?(:puts) && !destination.is_a?(String)
        block.call(destination)
      else
        File.open(destination.to_s, "w", &block)
      end
    end

    # Internal: rebuild an Event from a parsed JSON row and append it
    # to @events with its original identity. Used by Log.load.
    def restore(row)
      type    = row.fetch(:type).to_sym
      payload = restore_payload(type, row.fetch(:payload))
      event   = Event.new(seq: row.fetch(:seq), id: row.fetch(:id),
                          type: type, payload: payload)
      @events << event
    end

    def restore_payload(type, payload)
      result = payload.dup
      Array(PAYLOAD_SYMBOL_FIELDS[type]).each do |field|
        value = result[field]
        result[field] = value.to_sym if value.is_a?(String)
      end
      result
    end
  end
end
