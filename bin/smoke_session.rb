#!/usr/bin/env ruby
# frozen_string_literal: true

# End-to-end smoke: build a Session, append a user message, project
# the Log to a wire request, send it through a Provider (live or
# mock), ingest the response back into the Log as an
# :assistant_message Event, and print the assistant's text.
#
# Usage:
#   bundle exec bin/smoke_session.rb [--provider PROVIDER] [--mock] [--model MODEL] <prompt>
#
#   --provider PROVIDER   one of: anthropic (default), openai, gemini
#   --mock                replay the recorded fixture for this provider's
#                         hello-one-word case (offline, no API key needed);
#                         only useful with the prompt 'say hello in one word'
#   --model MODEL         override the default model from config/defaults.yml

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "fileutils"
require "optparse"
require "dotenv/load"
require "json"

require_relative "../lib/harnas/config"
require_relative "../lib/harnas/session"
require_relative "../lib/harnas/events/user_message"

require_relative "../lib/harnas/projections/anthropic"
require_relative "../lib/harnas/projections/openai"
require_relative "../lib/harnas/projections/gemini"

require_relative "../lib/harnas/providers/anthropic"
require_relative "../lib/harnas/providers/openai"
require_relative "../lib/harnas/providers/gemini"
require_relative "../lib/harnas/providers/mock"

require_relative "../lib/harnas/ingestors/anthropic"
require_relative "../lib/harnas/ingestors/openai"
require_relative "../lib/harnas/ingestors/gemini"

PROVIDER_KEY_ENV = {
  anthropic: "ANTHROPIC_API_KEY",
  openai: "OPENAI_API_KEY",
  gemini: "GEMINI_API_KEY"
}.freeze

PROJECTIONS = {
  anthropic: Harnas::Projections::Anthropic,
  openai: Harnas::Projections::OpenAI,
  gemini: Harnas::Projections::Gemini
}.freeze

PROVIDERS = {
  anthropic: Harnas::Providers::Anthropic,
  openai: Harnas::Providers::OpenAI,
  gemini: Harnas::Providers::Gemini
}.freeze

INGESTORS = {
  anthropic: Harnas::Ingestors::Anthropic,
  openai: Harnas::Ingestors::OpenAI,
  gemini: Harnas::Ingestors::Gemini
}.freeze

options = { provider: :anthropic, mock: false, model: nil }

parser = OptionParser.new do |opts|
  opts.banner = "usage: bin/smoke_session.rb " \
                "[--provider PROVIDER] [--mock] [--model MODEL] <prompt>"
  opts.on("--provider PROVIDER", PROVIDERS.keys.map(&:to_s),
          "anthropic | openai | gemini") { |p| options[:provider] = p.to_sym }
  opts.on("--mock", "Replay the recorded hello-one-word fixture") { options[:mock] = true }
  opts.on("--model MODEL", "Override the default model")          { |m| options[:model] = m }
  opts.on("-h", "--help") do
    puts opts
    exit
  end
end
parser.parse!

prompt = ARGV.join(" ")
if prompt.empty?
  warn parser.banner
  exit 1
end

provider_key = options[:provider]
config       = Harnas::Config.for_provider(provider_key)
model        = options[:model] || ENV["#{provider_key.to_s.upcase}_MODEL"] || config.fetch(:model)

# 1. Build the Session and append the user-message Event.
session = Harnas::Session.create(metadata: { provider: provider_key })
session.log.append(
  type: :user_message,
  payload: Harnas::Events::UserMessage.new(text: prompt).to_h
)

# 2. Project the Log to a wire request hash.
projection = PROJECTIONS[provider_key].new(model: model)
request    = projection.call(session.log)

# 3. Build a Provider — live or fixture-backed — and call it.
provider =
  if options[:mock]
    fixture_dir = File.expand_path(
      "../../spec/conformance/fixtures/hello-one-word/#{provider_key}",
      __dir__
    )
    Harnas::Providers::Mock.new(fixture_path: fixture_dir)
  else
    api_key_env = PROVIDER_KEY_ENV.fetch(provider_key)
    api_key = ENV.fetch(api_key_env) do
      warn "error: #{api_key_env} is not set"
      exit 1
    end
    if provider_key == :anthropic
      PROVIDERS[provider_key].new(api_key: api_key, api_version: config.fetch(:api_version))
    else
      PROVIDERS[provider_key].new(api_key: api_key)
    end
  end

begin
  response = provider.call(request)
rescue Harnas::Providers::HTTPError => e
  warn "error: HTTP #{e.status}"
  warn JSON.pretty_generate(e.body)
  exit 1
rescue Harnas::Providers::Error => e
  warn "error: #{e.message}"
  exit 1
end

# 4. Ingest the response into the Log as one or more Events.
ingestor = INGESTORS[provider_key].new
events   = ingestor.call(response)
events.each { |e| session.log.append(**e) }

# 5. Print the assistant's text (from the first :assistant_message event).
assistant_payload = events.find { |e| e[:type] == :assistant_message }[:payload]
puts assistant_payload[:text]

# Brief diagnostic to stderr so the Log isn't invisible.
warn "── session #{session.id} ─ events: #{session.log.size} " \
     "(seq=0 user_message → seq=#{session.log.size - 1} " \
     "assistant_message :#{assistant_payload[:stop_reason]})"
