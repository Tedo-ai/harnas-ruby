# frozen_string_literal: true

require "harnas/log"

RSpec.describe Harnas::Log do
  let(:log) { described_class.new }

  it "starts empty" do
    expect(log.size).to eq(0)
  end

  it "assigns sequential seq numbers starting at 0" do
    a = log.append(type: :user_message, payload: { text: "first" })
    b = log.append(type: :assistant_message, payload: { text: "second" })
    expect(a.seq).to eq(0)
    expect(b.seq).to eq(1)
  end

  it "returns the appended Event with seq and id set" do
    event = log.append(type: :user_message, payload: { text: "hi" })
    expect(event).to be_a(Harnas::Event)
    expect(event.seq).to eq(0)
    expect(event.id).to match(/^evt_0_[a-f0-9]{12}$/)
  end

  it "iterates events in insertion order" do
    log.append(type: :user_message, payload: { text: "a" })
    log.append(type: :user_message, payload: { text: "b" })
    log.append(type: :user_message, payload: { text: "c" })
    expect(log.map(&:payload)).to eq([{ text: "a" }, { text: "b" }, { text: "c" }])
  end

  it "looks up an event by seq with #at" do
    log.append(type: :user_message, payload: { text: "first" })
    second = log.append(type: :user_message, payload: { text: "second" })
    expect(log.at(1)).to eq(second)
  end

  it "returns events after a given seq with #since" do
    log.append(type: :user_message, payload: { text: "a" })
    log.append(type: :user_message, payload: { text: "b" })
    third = log.append(type: :user_message, payload: { text: "c" })
    expect(log.since(1)).to eq([third])
  end

  describe "persistence" do
    require "tempfile"

    def roundtrip(log)
      Tempfile.create(["harnas-log", ".jsonl"]) do |f|
        log.save(f.path)
        Harnas::Log.load(f.path)
      end
    end

    it "writes one JSON object per event, in seq order" do
      log.append(type: :user_message, payload: { text: "a" })
      log.append(type: :user_message, payload: { text: "b" })

      Tempfile.create(["harnas-log", ".jsonl"]) do |f|
        log.save(f.path)
        lines = File.readlines(f.path, chomp: true)
        expect(lines.size).to eq(2)
        parsed = lines.map { |l| JSON.parse(l) }
        expect(parsed.map { |r| r["seq"] }).to eq([0, 1])
        expect(parsed.map { |r| r["payload"]["text"] }).to eq(%w[a b])
      end
    end

    it "round-trips a plain text Log exactly (seq, id, type, payload)" do
      log.append(type: :user_message, payload: { text: "hi" })
      original_events = log.to_a

      loaded = roundtrip(log)

      expect(loaded.size).to eq(1)
      expect(loaded.to_a).to eq(original_events)
    end

    it "re-symbolizes assistant_message.stop_reason on load" do
      log.append(type: :user_message, payload: { text: "hi" })
      log.append(
        type: :assistant_message,
        payload: {
          text: "ok", stop_reason: :end_turn,
          usage: { input_tokens: 1, output_tokens: 1 }
        }
      )

      loaded = roundtrip(log)
      asst = loaded.find { |e| e.type == :assistant_message }
      expect(asst.payload[:stop_reason]).to eq(:end_turn)
    end

    it "round-trips a Log with tool_use + tool_result + compact mutations" do
      log.append(type: :user_message, payload: { text: "hi" })
      log.append(type: :tool_use,
                 payload: { id: "call_1", name: "f", arguments: { x: 1 } })
      log.append(type: :tool_result,
                 payload: { tool_use_id: "call_1", output: "42" })
      log.append(type: :compact, payload: { replaces: [0, 1, 2], summary: "snip" })

      loaded = roundtrip(log)
      expect(loaded.to_a).to eq(log.to_a)
    end

    it "preserves the original id rather than restamping" do
      first = log.append(type: :user_message, payload: { text: "hi" })
      loaded = roundtrip(log)
      expect(loaded.first.id).to eq(first.id)
    end

    it "ignores blank lines when loading" do
      Tempfile.create(["harnas-log", ".jsonl"]) do |f|
        log.append(type: :user_message, payload: { text: "hi" })
        log.save(f.path)
        File.open(f.path, "a") { |io| io.puts "" }

        loaded = Harnas::Log.load(f.path)
        expect(loaded.size).to eq(1)
      end
    end

    it "accepts an open IO on #save and .load" do
      log.append(type: :user_message, payload: { text: "hi" })
      io = StringIO.new
      log.save(io)
      io.rewind

      loaded = Harnas::Log.load(io)
      expect(loaded.to_a).to eq(log.to_a)
    end
  end
end
