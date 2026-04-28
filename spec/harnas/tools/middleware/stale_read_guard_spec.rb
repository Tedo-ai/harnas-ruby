# frozen_string_literal: true

require "tempfile"
require "tmpdir"
require "harnas/log"
require "harnas/session"
require "harnas/tools/builtin"
require "harnas/tools/middleware/stale_read_guard"
require "harnas/observation"

RSpec.describe Harnas::Tools::Middleware::StaleReadGuard do
  let(:read_handler)  { Harnas::Tools::Builtin.method(:read_file) }
  let(:edit_handler)  { Harnas::Tools::Builtin.method(:edit_file) }
  let(:write_handler) { Harnas::Tools::Builtin.method(:write_file) }

  def with_file(content)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "note.txt")
      File.write(path, content)
      yield path
    end
  end

  describe "strict mode (default)" do
    let(:log)   { Harnas::Log.new }
    let(:guard) { described_class.new(log: log) }

    it "allows a read → edit flow when the file has not drifted" do
      with_file("alpha\nbravo\n") do |path|
        guard.wrap_read(read_handler).call(path: path)
        expect do
          guard.wrap_edit(edit_handler).call(
            path: path, old_string: "alpha", new_string: "ALPHA"
          )
        end.not_to raise_error
        expect(File.read(path)).to eq("ALPHA\nbravo\n")
      end
    end

    it "refuses to edit a file that was never read" do
      with_file("content\n") do |path|
        expect do
          guard.wrap_edit(edit_handler).call(
            path: path, old_string: "content", new_string: "CONTENT"
          )
        end.to raise_error(described_class::StaleReadError, /never read/)
      end
    end

    it "refuses to edit a file whose disk content has drifted since the last read" do
      with_file("original\n") do |path|
        guard.wrap_read(read_handler).call(path: path)
        File.write(path, "changed externally\n")

        expect do
          guard.wrap_edit(edit_handler).call(
            path: path, old_string: "changed externally", new_string: "!"
          )
        end.to raise_error(described_class::StaleReadError, /drifted/)
      end
    end

    it "applies the same check to write_file" do
      with_file("x\n") do |path|
        expect do
          guard.wrap_write(write_handler).call(path: path, content: "y\n")
        end.to raise_error(described_class::StaleReadError)
      end
    end

    it "refreshes the known hash after a successful edit, enabling a second edit" do
      with_file("alpha\n") do |path|
        guard.wrap_read(read_handler).call(path: path)
        guard.wrap_edit(edit_handler).call(
          path: path, old_string: "alpha", new_string: "bravo"
        )
        expect do
          guard.wrap_edit(edit_handler).call(
            path: path, old_string: "bravo", new_string: "charlie"
          )
        end.not_to raise_error
      end
    end
  end

  describe "observe-only mode" do
    it "does not raise on drift, but emits :stale_read_guard_fired" do
      log   = Harnas::Log.new
      guard = described_class.new(log: log, strict: false)

      events = []
      Harnas::Observation.subscribe(
        ->(ev, p) { events << p if ev == :stale_read_guard_fired }
      )

      with_file("one\n") do |path|
        guard.wrap_read(read_handler).call(path: path)
        File.write(path, "two\n")

        expect do
          guard.wrap_edit(edit_handler).call(
            path: path, old_string: "two", new_string: "TWO"
          )
        end.not_to raise_error
      end

      expect(events.size).to be >= 1
      expect(events.first[:strict]).to be(false)
      expect(events.first[:reason]).to eq(:drifted)
    ensure
      Harnas::Observation.reset!
    end
  end

  describe "require_read: false" do
    it "lets first-time edits through when the file has never been read" do
      log   = Harnas::Log.new
      guard = described_class.new(log: log, strict: true, require_read: false)

      with_file("content\n") do |path|
        expect do
          guard.wrap_edit(edit_handler).call(
            path: path, old_string: "content", new_string: "CONTENT"
          )
        end.not_to raise_error
      end
    end

    it "still refuses when a prior read exists and content has drifted" do
      log   = Harnas::Log.new
      guard = described_class.new(log: log, strict: true, require_read: false)

      with_file("a\n") do |path|
        guard.wrap_read(read_handler).call(path: path)
        File.write(path, "b\n")

        expect do
          guard.wrap_edit(edit_handler).call(
            path: path, old_string: "b", new_string: "!"
          )
        end.to raise_error(described_class::StaleReadError, /drifted/)
      end
    end
  end

  describe "event sourcing" do
    it "appends an :annotation Event to the Log on every recorded view" do
      log   = Harnas::Log.new
      guard = described_class.new(log: log)

      with_file("hello\n") do |path|
        guard.wrap_read(read_handler).call(path: path)
        expect(log.map(&:type)).to include(:annotation)

        annotation = log.reverse_each.find { |e| e.type == :annotation }
        expect(annotation.payload[:kind]).to eq("stale_read_guard.hash")
        expect(annotation.payload[:data][:path]).to eq(path)
        expect(annotation.payload[:data][:sha256]).to match(/\A[0-9a-f]{64}\z/)
      end
    end

    it "derives last_hash_for from the Log, not from instance state" do
      log = Harnas::Log.new
      a   = described_class.new(log: log)

      with_file("hello\n") do |path|
        a.wrap_read(read_handler).call(path: path)

        # A fresh guard bound to the same Log sees the same state.
        b = described_class.new(log: log)
        expect(b.known?(path)).to be(true)
        expect(b.last_hash_for(path)).to eq(a.last_hash_for(path))
      end
    end

    it "survives Session.save + Session.load round-trip" do
      Dir.mktmpdir do |dir|
        source_path = File.join(dir, "note.txt")
        File.write(source_path, "persistent\n")

        session = Harnas::Session.create
        guard   = described_class.new(log: session.log)
        guard.wrap_read(read_handler).call(path: source_path)

        saved_path = File.join(dir, "session.jsonl")
        session.save(saved_path)

        loaded = Harnas::Session.load(saved_path)
        reborn = described_class.new(log: loaded.log)

        expect(reborn.known?(source_path)).to be(true)
        expect do
          reborn.wrap_edit(edit_handler).call(
            path: source_path, old_string: "persistent", new_string: "reloaded"
          )
        end.not_to raise_error
      end
    end
  end
end
