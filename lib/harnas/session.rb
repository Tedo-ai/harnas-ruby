# frozen_string_literal: true

require "json"
require "securerandom"
require "harnas/hooks"
require "harnas/log"
require "harnas/observation"

module Harnas
  # JSONL marker for the one-line session header that precedes
  # the event stream when a Session is persisted to a single file.
  SESSION_HEADER_KEY = "__session__"

  # A Session bundles a stable identifier with one Log and an optional
  # metadata bag (provider, surface, situation, started_at, etc.).
  #
  # The Session itself is a frozen value object, but the Log it owns is
  # mutable: `session.log.append(...)` continues to work after the
  # Session has been constructed.
  Session = Data.define(:id, :log, :metadata, :hooks, :observation) do
    def initialize(id:, log: nil, metadata: {}, hooks: nil, observation: nil)
      raise ArgumentError, "id must be a String"        unless id.is_a?(String)
      raise ArgumentError, "id must not be empty"       if id.empty?
      raise ArgumentError, "metadata must be a Hash"    unless metadata.is_a?(Hash)

      observation ||= Observation.new
      hooks       ||= Hooks.new
      log         ||= Log.new(observation: observation)

      raise ArgumentError, "log must be a Harnas::Log" unless log.is_a?(Log)
      raise ArgumentError, "hooks must be a Harnas::Hooks" unless hooks.is_a?(Hooks)
      raise ArgumentError, "observation must be a Harnas::Observation" \
        unless observation.is_a?(Observation)

      log.observation ||= observation

      super
    end

    # Convenience constructor: generates a UUID-suffixed id and a fresh Log.
    def self.create(metadata: {})
      new(id: "ses_#{SecureRandom.uuid}", metadata: metadata)
    end

    def install(strategy, **config)
      strategy.install(self, **config)
    end

    def ==(other)
      other.is_a?(self.class) &&
        id == other.id &&
        log.equal?(other.log) &&
        metadata == other.metadata
    end

    # Persist the Session as a JSONL file: one header line carrying
    # the Session id + metadata, then one line per event in seq order.
    # The file round-trips losslessly through Session.load.
    def save(destination)
      if destination.respond_to?(:puts) && !destination.is_a?(String)
        write_to(destination)
      else
        File.open(destination.to_s, "w") { |io| write_to(io) }
      end
      self
    end

    # Read a file written by #save and return the restored Session
    # (same id, metadata, and Log contents).
    def self.load(source)
      if io_like?(source)
        load_from_io(source)
      else
        File.open(source.to_s, "r") { |io| load_from_io(io) }
      end
    end

    def self.io_like?(source)
      source.respond_to?(:each_line) && source.respond_to?(:read) &&
        !source.is_a?(String)
    end
    private_class_method :io_like?

    def self.load_from_io(io)
      header, events = split_header(io)
      log = Log.new
      events.each { |row| log.send(:restore, row) }
      new(
        id: header.fetch(:id),
        log: log,
        metadata: header.fetch(:metadata, {})
      )
    end
    private_class_method :load_from_io

    def self.split_header(io)
      rows = io.each_line.filter_map do |line|
        trimmed = line.strip
        trimmed.empty? ? nil : JSON.parse(trimmed, symbolize_names: true)
      end
      header_key = Harnas::SESSION_HEADER_KEY.to_sym
      raise ArgumentError, "session file is empty" if rows.empty?
      raise ArgumentError, "missing session header" unless rows.first[header_key]

      [rows.first, rows.drop(1)]
    end
    private_class_method :split_header

    private

    def write_to(io)
      io.puts JSON.generate(
        Harnas::SESSION_HEADER_KEY => true,
        "id" => id,
        "metadata" => metadata
      )
      log.each do |event|
        io.puts JSON.generate(
          seq: event.seq,
          id: event.id,
          type: event.type.to_s,
          payload: event.payload
        )
      end
    end
  end
end
