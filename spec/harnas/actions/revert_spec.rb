# frozen_string_literal: true

require "harnas/actions/revert"
require "harnas/actions/compact"
require "harnas/session"
require "harnas/events/user_message"

RSpec.describe Harnas::Actions::Revert do
  let(:session) { Harnas::Session.create }

  before do
    session.log.append(
      type: :user_message,
      payload: Harnas::Events::UserMessage.new(text: "m").to_h
    )
    @compact = Harnas::Actions::Compact.call(session, replaces: [0], summary: "s")
  end

  it "appends a :revert event to the Session's Log" do
    described_class.call(session, revokes: @compact.seq)
    revert = session.log.find { |e| e.type == :revert }
    expect(revert).not_to be_nil
  end

  it "carries revokes through to the event payload" do
    described_class.call(session, revokes: @compact.seq)
    revert = session.log.find { |e| e.type == :revert }
    expect(revert.payload[:revokes]).to eq(@compact.seq)
  end

  it "rejects a negative revokes via Events::Revert validation" do
    expect { described_class.call(session, revokes: -1) }
      .to raise_error(ArgumentError, /revokes must be a non-negative Integer/)
  end
end
