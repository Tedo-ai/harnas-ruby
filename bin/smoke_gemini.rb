#!/usr/bin/env ruby
# frozen_string_literal: true

# Smoke test: send a single prompt to Google Gemini's generateContent API.
#
# Usage:
#   bundle exec bin/smoke_gemini.rb [--model MODEL] [--record DIR] [--mock DIR] <prompt>
#
# Resolution order for the model:
#   1. --model CLI flag
#   2. GEMINI_MODEL environment variable
#   3. Default from config/defaults.yml
#
# Modes:
#   live  — (default) calls the real API using GEMINI_API_KEY
#   mock  — replays a recorded fixture (--mock DIR), offline, no key needed
#   live + --record DIR  — also writes request.json/response.json to DIR

require "fileutils"
require "optparse"
require "dotenv/load"
require "json"
require_relative "../lib/harnas/config"
require_relative "../lib/harnas/providers/gemini"
require_relative "../lib/harnas/providers/mock"

options = { model: nil, record: nil, mock: nil }

parser = OptionParser.new do |opts|
  opts.banner = "usage: bin/smoke_gemini.rb [--model MODEL] [--record DIR] [--mock DIR] <prompt>"
  opts.on("--model MODEL", "Model identifier") { |m| options[:model] = m }
  opts.on("--record DIR", "Write request.json/response.json to DIR after a successful call") do |d|
    options[:record] = d
  end
  opts.on("--mock DIR", "Replay a recorded fixture from DIR instead of the live API") do |d|
    options[:mock] = d
  end
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

config = Harnas::Config.for_provider(:gemini)
model  = options[:model] || ENV["GEMINI_MODEL"] || config.fetch(:model)

request = {
  model: model,
  contents: [
    { role: "user", parts: [{ text: prompt }] }
  ]
}

provider =
  if options[:mock]
    Harnas::Providers::Mock.new(fixture_path: options[:mock])
  else
    begin
      api_key = ENV.fetch("GEMINI_API_KEY")
    rescue KeyError
      warn "error: GEMINI_API_KEY is not set"
      warn "get one at https://aistudio.google.com/app/apikey"
      exit 1
    end
    Harnas::Providers::Gemini.new(api_key: api_key)
  end

begin
  response = provider.call(request)
rescue Harnas::Providers::HTTPError => e
  warn "error: HTTP #{e.status} from Gemini"
  warn JSON.pretty_generate(e.body)
  exit 1
rescue Harnas::Providers::Error => e
  warn "error: #{e.message}"
  exit 1
end

text = response.dig("candidates", 0, "content", "parts", 0, "text")
if text.nil? || text.empty?
  warn "error: response contained no text content"
  warn JSON.pretty_generate(response)
  exit 1
end

puts text

if options[:record]
  FileUtils.mkdir_p(options[:record])
  File.write(
    File.join(options[:record], "request.json"),
    "#{JSON.pretty_generate(request)}\n"
  )
  File.write(
    File.join(options[:record], "response.json"),
    "#{JSON.pretty_generate(response)}\n"
  )
  warn "recorded fixture to #{options[:record]}"
end
