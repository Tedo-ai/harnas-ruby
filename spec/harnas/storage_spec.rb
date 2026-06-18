# frozen_string_literal: true

require "json"
require "spec_helper"
require "tempfile"
require "harnas/storage"

RSpec.describe Harnas::Storage do
  def draft_from_hash(hash)
    described_class::EventDraft.new(
      id: hash.fetch("id"),
      timestamp: hash.fetch("timestamp"),
      type: hash.fetch("type").to_sym,
      payload: hash.fetch("payload")
    )
  end

  def expect_row(row, expected)
    expect(row.seq).to eq(expected.fetch("seq"))
    expect(row.id).to eq(expected.fetch("id"))
    expect(row.timestamp).to eq(expected.fetch("timestamp"))
    expect(row.type.to_s).to eq(expected.fetch("type"))
    expect(row.payload).to eq(expected.fetch("payload"))
  end

  it "passes the OCC conditional append storage-law fixture" do
    law_path = File.join(
      HarnasSpecPaths.spec_root,
      "conformance/storage-laws/occ-conditional-append/law.json"
    )
    law = JSON.parse(File.read(law_path))
    adapter = described_class::MemoryAdapter.new

    law.fetch("operations").each do |operation|
      case operation.fetch("op")
      when "append_event"
        expect_spec = operation.fetch("expect")
        if expect_spec.fetch("ok")
          row = adapter.append_event(
            draft_from_hash(operation.fetch("draft")),
            expected_next_seq: operation["expected_next_seq"]
          )
          expect_row(row, expect_spec.fetch("row"))
        else
          expect do
            adapter.append_event(
              draft_from_hash(operation.fetch("draft")),
              expected_next_seq: operation["expected_next_seq"]
            )
          end.to raise_error(described_class::ConflictError) { |error|
            expect(error.reason).to eq(expect_spec.fetch("reason"))
            expect(error.current_next_seq).to eq(expect_spec.fetch("current_next_seq"))
          }
        end
      when "events_since"
        rows = adapter.events_since(operation["cursor"])
        expect(rows.size).to eq(operation.fetch("expect").fetch("rows").size)
        rows.zip(operation.fetch("expect").fetch("rows")).each do |row, expected|
          expect_row(row, expected)
        end
      else
        raise "unknown op #{operation.fetch("op")}"
      end
    end
  end

  it "persists headers, dense events, cursors, and loud torn-line failures" do
    Tempfile.create(["harnas-storage", ".jsonl"]) do |file|
      adapter = described_class::FileAdapter.new(file.path)
      header = described_class::SessionHeader.new(
        id: "ses_storage",
        metadata: { "label" => "storage" },
        parent_session_id: nil,
        root_session_id: nil,
        spawn_id: nil,
        spawned_by_event_id: nil,
        delegation_chain: []
      )
      adapter.save_header(header)
      expect(adapter.load_session).to eq(header)

      row0 = adapter.append_event(described_class::EventDraft.new(
                                    id: "evt_0",
                                    timestamp: "2026-06-16T10:00:00Z",
                                    type: :user_message,
                                    payload: { "content" => [{ "type" => "text",
                                                               "text" => "one" }] }
                                  ))
      expect(row0.seq).to eq(0)
      row1 = described_class::FileAdapter.new(file.path).append_event(
        described_class::EventDraft.new(
          id: "evt_1",
          timestamp: "2026-06-16T10:00:01Z",
          type: :assistant_message,
          payload: { "content" => [{ "type" => "text", "text" => "two" }] }
        )
      )
      expect(row1.seq).to eq(1)
      expect(adapter.events_since(0).map(&:id)).to eq(["evt_1"])

      File.open(file.path, "a") { |io| io.write("{\"seq\":") }
      expect { described_class::FileAdapter.new(file.path).events_since(nil) }
        .to raise_error(JSON::ParserError)
    end
  end
end
