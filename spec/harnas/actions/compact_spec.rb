# frozen_string_literal: true

require "harnas/actions/compact"
require "harnas/session"
require "harnas/events/user_message"

RSpec.describe Harnas::Actions::Compact do
  let(:session) { Harnas::Session.create }

  before do
    3.times do |i|
      session.log.append(
        type: :user_message,
        payload: Harnas::Events::UserMessage.new(text: "m#{i}").to_h
      )
    end
  end

  it "appends a :compact event to the Session's Log" do
    described_class.call(session, replaces: [0, 1], summary: "earlier talk")
    compact = session.log.find { |e| e.type == :compact }
    expect(compact).not_to be_nil
  end

  it "carries replaces and summary through to the event payload" do
    described_class.call(session, replaces: [0, 1], summary: "earlier talk")
    compact = session.log.find { |e| e.type == :compact }
    expect(compact.payload[:replaces]).to eq([0, 1])
    expect(compact.payload[:summary]).to eq("earlier talk")
  end

  it "validates inputs via Events::Compact — rejects empty replaces" do
    expect { described_class.call(session, replaces: [], summary: "x") }
      .to raise_error(ArgumentError, /replaces must not be empty/)
  end

  it "validates inputs via Events::Compact — rejects empty summary" do
    expect { described_class.call(session, replaces: [0], summary: "") }
      .to raise_error(ArgumentError, /summary must not be empty/)
  end

  it "returns the appended Event" do
    result = described_class.call(session, replaces: [0, 1], summary: "x")
    expect(result).to be_a(Harnas::Event)
    expect(result.type).to eq(:compact)
  end
end
