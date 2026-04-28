# frozen_string_literal: true

require "spec_helper"
require "harnas/log"
require "harnas/mutations"
require "harnas/projections/anthropic"
require "harnas/session"

RSpec.describe "Log properties" do
  def serialize(events)
    events.map { |event| [event.seq, event.type, event.payload] }
  end

  def random_text(index)
    "message-#{index}-#{rand(10_000)}"
  end

  def append_random_message(log, index)
    type = index.even? ? :user_message : :assistant_message
    payload = { text: random_text(index) }
    payload[:stop_reason] = :end_turn if type == :assistant_message
    payload[:usage] = { input_tokens: 0, output_tokens: 0 } if type == :assistant_message
    log.append(type: type, payload: payload)
  end

  def random_log(message_count: rand(1..12), compact: true)
    log = Harnas::Log.new
    message_count.times { |index| append_random_message(log, index) }
    if compact && message_count >= 4 && rand < 0.6
      upper = rand(1...(message_count - 1))
      log.append(type: :compact, payload: {
                   replaces: (0..upper).to_a,
                   summary: "summary up to #{upper}"
                 })
    end
    log
  end

  it "Mutations.apply is idempotent" do
    100.times do
      log = random_log
      once = Harnas::Mutations.apply(log)
      twice = Harnas::Mutations.apply(once)
      expect(serialize(twice)).to eq(serialize(once))
    end
  end

  it "projections are pure" do
    100.times do
      log = random_log
      projection = Harnas::Projections::Anthropic.new(model: "claude-test", max_tokens: 128)
      expect(projection.call(log)).to eq(projection.call(log))
    end
  end

  it "append preserves dense seq order" do
    100.times do
      log = random_log(compact: false)
      expect(log.map(&:seq)).to eq((0...log.size).to_a)
    end
  end

  it "fork preserves the selected prefix" do
    100.times do
      session = Harnas::Session.create
      rand(1..12).times { |index| append_random_message(session.log, index) }
      at_seq = rand(0...session.log.size)
      forked = session.fork(at_seq: at_seq)

      expect(serialize(forked.log)).to eq(serialize(session.log.first(at_seq + 1)))
      expect(forked.metadata[:forked_from]).to eq(session.id)
      expect(forked.metadata[:forked_at_seq]).to eq(at_seq)
    end
  end

  it "compact + revert composes back to the original effective stream" do
    100.times do
      log = random_log(message_count: rand(2..8), compact: false)
      original = Harnas::Mutations.apply(log)
      compact = log.append(type: :compact, payload: {
                             replaces: (0...log.size).to_a,
                             summary: "temporary summary"
                           })
      log.append(type: :revert, payload: { revokes: compact.seq })

      expect(serialize(Harnas::Mutations.apply(log))).to eq(serialize(original))
    end
  end
end
