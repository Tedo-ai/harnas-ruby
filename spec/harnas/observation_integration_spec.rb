# frozen_string_literal: true

require "harnas/observation"
require "harnas/session"
require "harnas/events/user_message"
require "harnas/events/compact"
require "harnas/projections/anthropic"
require "harnas/projections/openai"
require "harnas/projections/gemini"
require "harnas/providers/mock"
require "harnas/ingestors/anthropic"
require "harnas/ingestors/openai"
require "harnas/ingestors/gemini"

RSpec.describe "Observation integration" do
  before { Harnas::Observation.reset! }
  after  { Harnas::Observation.reset! }

  def fixture_dir(provider)
    File.expand_path(
      "../../../spec/conformance/fixtures/hello-one-word/#{provider}",
      __dir__
    )
  end

  describe "a full smoke session" do
    it "emits the expected event sequence end-to-end (Anthropic mock)" do
      collector = nil
      Harnas::Observation.subscribed do |c|
        collector = c
        session = Harnas::Session.create(metadata: { provider: :anthropic })
        session.log.append(
          type: :user_message,
          payload: Harnas::Events::UserMessage.new(text: "say hello in one word").to_h
        )

        projection = Harnas::Projections::Anthropic.new(model: "claude-sonnet-4-5")
        provider   = Harnas::Providers::Mock.new(fixture_path: fixture_dir(:anthropic))
        ingestor   = Harnas::Ingestors::Anthropic.new

        response = provider.call(projection.call(session.log))
        ingestor.call(response).each { |e| session.log.append(**e) }
      end

      types = collector.events.map(&:first)
      expect(types).to eq(%i[
                            event_appended
                            mutation_applied
                            projection_invoked
                            provider_called
                            provider_responded
                            tokens_consumed
                            event_appended
                          ])
    end

    it "emits identical event-name sequences for OpenAI and Gemini mocks" do
      anthropic_types = run_mock_session(:anthropic).events.map(&:first)
      openai_types    = run_mock_session(:openai).events.map(&:first)
      gemini_types    = run_mock_session(:gemini).events.map(&:first)

      expect(openai_types).to eq(anthropic_types)
      expect(gemini_types).to eq(anthropic_types)
    end
  end

  describe "individual event payloads" do
    it ":event_appended carries the Event and post-append log_size" do
      Harnas::Observation.subscribed do |c|
        log = Harnas::Log.new
        evt = log.append(type: :user_message, payload: { text: "hi" })

        e = c.of(:event_appended).first
        expect(e[1][:event]).to eq(evt)
        expect(e[1][:log_size]).to eq(1)
      end
    end

    it ":projection_invoked carries projection identifier, log_size, and the request" do
      Harnas::Observation.subscribed do |c|
        log = Harnas::Log.new
        log.append(type: :user_message, payload: { text: "hi" })

        Harnas::Projections::Anthropic.new(model: "x").call(log)

        e = c.of(:projection_invoked).first
        expect(e[1][:projection]).to eq(:anthropic)
        expect(e[1][:log_size]).to eq(1)
        expect(e[1][:request]).to include(:model, :max_tokens, :messages)
      end
    end

    it ":provider_called and :provider_responded bracket the call with duration_ms" do
      Harnas::Observation.subscribed do |c|
        provider = Harnas::Providers::Mock.new(fixture_path: fixture_dir(:anthropic))
        provider.call(JSON.parse(File.read(File.join(fixture_dir(:anthropic), "request.json"))))

        called    = c.of(:provider_called).first[1]
        responded = c.of(:provider_responded).first[1]
        expect(called[:provider]).to eq(:mock)
        expect(responded[:provider]).to eq(:mock)
        expect(responded[:duration_ms]).to be_a(Integer)
        expect(responded[:duration_ms]).to be >= 0
      end
    end

    it ":provider_failed fires when the call raises (with duration_ms and error)" do
      Harnas::Observation.subscribed do |c|
        provider = Harnas::Providers::Mock.new(fixture_path: fixture_dir(:anthropic))
        expect { provider.call("model" => "wrong") }
          .to raise_error(Harnas::Providers::FixtureError)

        e = c.of(:provider_failed).first[1]
        expect(e[:provider]).to eq(:mock)
        expect(e[:error]).to be_a(Harnas::Providers::FixtureError)
        expect(e[:duration_ms]).to be_a(Integer)
      end
    end

    it ":mutation_applied carries log_size, effective_size, and applied_count" do
      Harnas::Observation.subscribed do |c|
        log = Harnas::Log.new
        log.append(type: :user_message, payload: { text: "a" })
        log.append(type: :user_message, payload: { text: "b" })
        log.append(
          type: :compact,
          payload: Harnas::Events::Compact.new(replaces: [0, 1], summary: "S").to_h
        )

        Harnas::Projections::Anthropic.new(model: "x").call(log)

        e = c.of(:mutation_applied).first[1]
        expect(e[:log_size]).to eq(3)
        expect(e[:effective_size]).to eq(1)
        expect(e[:applied_count]).to eq(1)
      end
    end

    it ":tokens_consumed carries the normalized token counts from the Ingestor" do
      Harnas::Observation.subscribed do |c|
        recorded = JSON.parse(File.read(File.join(fixture_dir(:anthropic), "response.json")))
        Harnas::Ingestors::Anthropic.new.call(recorded)

        e = c.of(:tokens_consumed).first[1]
        expect(e[:provider]).to eq(:anthropic)
        expect(e[:input_tokens]).to be_positive
        expect(e[:output_tokens]).to be_positive
      end
    end
  end

  describe "no-subscriber path" do
    it "is a no-op when no subscribers are registered" do
      log = Harnas::Log.new
      expect { log.append(type: :user_message, payload: { text: "hi" }) }
        .not_to raise_error
    end
  end

  def run_mock_session(provider_key)
    projections = {
      anthropic: -> { Harnas::Projections::Anthropic.new(model: "claude-sonnet-4-5") },
      openai: -> { Harnas::Projections::OpenAI.new(model: "gpt-5.4-mini") },
      gemini: -> { Harnas::Projections::Gemini.new(model: "gemini-flash-latest") }
    }
    ingestors = {
      anthropic: Harnas::Ingestors::Anthropic,
      openai: Harnas::Ingestors::OpenAI,
      gemini: Harnas::Ingestors::Gemini
    }

    Harnas::Observation.reset!
    collector = Harnas::Observation::Collector.new
    Harnas::Observation.subscribe(collector)

    session = Harnas::Session.create(metadata: { provider: provider_key })
    session.log.append(
      type: :user_message,
      payload: Harnas::Events::UserMessage.new(text: "say hello in one word").to_h
    )

    projection = projections.fetch(provider_key).call
    provider   = Harnas::Providers::Mock.new(fixture_path: fixture_dir(provider_key))
    ingestor   = ingestors.fetch(provider_key).new

    response = provider.call(projection.call(session.log))
    ingestor.call(response).each { |e| session.log.append(**e) }

    collector
  end
end
