# frozen_string_literal: true

require "harnas/session"

RSpec.describe Harnas::Session do
  describe ".new" do
    it "holds id, log, and metadata" do
      log = Harnas::Log.new
      session = described_class.new(id: "ses_x", log: log, metadata: { provider: :anthropic })

      expect(session.id).to eq("ses_x")
      expect(session.log).to be(log)
      expect(session.metadata).to eq({ provider: :anthropic })
    end

    it "defaults log to a fresh empty Log" do
      session = described_class.new(id: "ses_x")
      expect(session.log).to be_a(Harnas::Log)
      expect(session.log.size).to eq(0)
    end

    it "defaults metadata to an empty Hash" do
      session = described_class.new(id: "ses_x")
      expect(session.metadata).to eq({})
    end

    it "is frozen (immutable)" do
      expect(described_class.new(id: "ses_x")).to be_frozen
    end

    it "rejects a non-String id" do
      expect { described_class.new(id: 123) }
        .to raise_error(ArgumentError, /id must be a String/)
    end

    it "rejects an empty id" do
      expect { described_class.new(id: "") }
        .to raise_error(ArgumentError, /id must not be empty/)
    end

    it "rejects a non-Log log" do
      expect { described_class.new(id: "ses_x", log: []) }
        .to raise_error(ArgumentError, /log must be a Harnas::Log/)
    end

    it "rejects a non-Hash metadata" do
      expect { described_class.new(id: "ses_x", metadata: nil) }
        .to raise_error(ArgumentError, /metadata must be a Hash/)
    end
  end

  describe ".create" do
    it "generates a ses_-prefixed UUID id" do
      session = described_class.create
      expect(session.id).to match(/\Ases_[0-9a-f-]{36}\z/)
    end

    it "produces distinct ids on each call" do
      a = described_class.create
      b = described_class.create
      expect(a.id).not_to eq(b.id)
    end

    it "starts with an empty Log" do
      expect(described_class.create.log.size).to eq(0)
    end

    it "accepts metadata" do
      session = described_class.create(metadata: { provider: :openai })
      expect(session.metadata).to eq({ provider: :openai })
    end
  end

  describe "log access" do
    it "exposes a mutable Log even though the Session is frozen" do
      session = described_class.create
      event = session.log.append(type: :user_message, payload: { text: "hi" })

      expect(session.log.size).to eq(1)
      expect(session.log.at(0)).to eq(event)
    end
  end

  describe "value equality" do
    it "is equal to another Session with the same id, log reference, and metadata" do
      log = Harnas::Log.new
      a = described_class.new(id: "ses_x", log: log, metadata: { k: 1 })
      b = described_class.new(id: "ses_x", log: log, metadata: { k: 1 })
      expect(a).to eq(b)
    end

    it "is not equal when ids differ" do
      log = Harnas::Log.new
      a = described_class.new(id: "ses_a", log: log)
      b = described_class.new(id: "ses_b", log: log)
      expect(a).not_to eq(b)
    end
  end

  describe "persistence" do
    require "tempfile"

    def roundtrip(session)
      Tempfile.create(["harnas-session", ".jsonl"]) do |f|
        session.save(f.path)
        Harnas::Session.load(f.path)
      end
    end

    it "round-trips id, metadata, and log events" do
      # Metadata values must be JSON-plain (String/Number/Bool/Array/Hash/null);
      # Symbols survive only as Hash keys, not as values. Callers who want
      # Symbol values should re-symbolize in their own adapter.
      session = described_class.new(
        id: "ses_persist", metadata: { provider: "anthropic", label: "demo" }
      )
      session.log.append(type: :user_message, payload: { text: "hi" })
      session.log.append(
        type: :assistant_message,
        payload: {
          text: "ok", stop_reason: :end_turn,
          usage: { input_tokens: 1, output_tokens: 1 }
        }
      )

      loaded = roundtrip(session)
      expect(loaded.id).to eq("ses_persist")
      expect(loaded.metadata).to eq({ provider: "anthropic", label: "demo" })
      expect(loaded.log.to_a).to eq(session.log.to_a)
    end

    it "writes a session-header line followed by one line per event" do
      session = described_class.new(id: "ses_h")
      session.log.append(type: :user_message, payload: { text: "hi" })

      Tempfile.create(["harnas-session", ".jsonl"]) do |f|
        session.save(f.path)
        lines = File.readlines(f.path, chomp: true)
        expect(lines.size).to eq(2)
        header = JSON.parse(lines.first)
        expect(header).to include("__session__" => true, "id" => "ses_h")
      end
    end

    it "raises when the file is missing a session header" do
      Tempfile.create(["harnas-log", ".jsonl"]) do |f|
        log = Harnas::Log.new
        log.append(type: :user_message, payload: { text: "hi" })
        log.save(f.path)
        expect { Harnas::Session.load(f.path) }
          .to raise_error(ArgumentError, /session header/)
      end
    end

    it "accepts a StringIO on save and load" do
      session = described_class.new(id: "ses_io")
      session.log.append(type: :user_message, payload: { text: "hi" })

      io = StringIO.new
      session.save(io)
      io.rewind

      loaded = Harnas::Session.load(io)
      expect(loaded.id).to eq("ses_io")
      expect(loaded.log.size).to eq(1)
    end
  end
end
