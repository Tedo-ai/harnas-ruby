# frozen_string_literal: true

require "json"
require "harnas/ingestors/anthropic"
require "harnas/ingestors/openai"
require "harnas/ingestors/gemini"
require "harnas/projections/anthropic"
require "harnas/projections/openai"
require "harnas/projections/gemini"
require "harnas/log"

RSpec.describe "provider carrier fixtures" do
  spec_root = ENV.fetch("HARNAS_SPEC") do
    File.expand_path("../../../harnas", __dir__)
  end
  carrier_root = File.join(spec_root, "conformance", "provider-carriers")

  Dir.glob(File.join(carrier_root, "*", "fixture.json")).sort.each do |fixture_path|
    name = File.basename(File.dirname(fixture_path))

    it "passes #{name}" do
      fixture = JSON.parse(File.read(fixture_path))

      events = ingestor_for(fixture.dig("provider", "kind")).call(fixture.dig("ingest", "provider_response"))
      actual = events.fetch(0)
      actual[:payload][:provider] ||= fixture.dig("provider", "kind")
      actual[:payload][:model] ||= fixture.dig("provider", "model")
      expect(normalize(actual)).to eq(normalize(symbolize_event(fixture.dig("ingest", "expect_event"))))

      log = Harnas::Log.new
      fixture.dig("project", "log").each do |row|
        log.append(type: row.fetch("type").to_sym, payload: deep_symbolize(row.fetch("payload")))
      end
      request = projection_for(fixture.dig("provider", "kind"), fixture.dig("provider", "model")).call(log)
      expect(normalize(request)).to eq(normalize(fixture.dig("project", "expect_request")))

      roundtrip = ingestor_for(fixture.dig("provider", "kind")).call(fixture.dig("ingest", "provider_response"))
      expect(normalize(roundtrip.fetch(0)[:payload].slice(:provider_items, :content, :reasoning).compact))
        .to eq(normalize(deep_symbolize(fixture.dig("ingest", "expect_event", "payload")).slice(:provider_items, :content, :reasoning).compact))
    end
  end

  def ingestor_for(kind)
    case kind
    when "anthropic" then Harnas::Ingestors::Anthropic.new
    when "openai" then Harnas::Ingestors::OpenAI.new
    when "gemini" then Harnas::Ingestors::Gemini.new
    else raise "unsupported provider kind #{kind.inspect}"
    end
  end

  def projection_for(kind, model)
    case kind
    when "anthropic" then Harnas::Projections::Anthropic.new(model: model, max_tokens: 1024)
    when "openai" then Harnas::Projections::OpenAI.new(model: model)
    when "gemini" then Harnas::Projections::Gemini.new(model: model)
    else raise "unsupported provider kind #{kind.inspect}"
    end
  end

  def symbolize_event(event)
    { type: event.fetch("type").to_sym, payload: deep_symbolize(event.fetch("payload")) }
  end

  def deep_symbolize(value)
    case value
    when Hash
      value.each_with_object({}) { |(key, val), out| out[key.to_sym] = deep_symbolize(val) }
    when Array
      value.map { |item| deep_symbolize(item) }
    else
      value
    end
  end

  def normalize(value)
    JSON.parse(JSON.generate(value))
  end
end
