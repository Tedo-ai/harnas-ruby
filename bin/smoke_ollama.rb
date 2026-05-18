#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require_relative "../lib/harnas/providers/ollama"

options = { model: ENV.fetch("OLLAMA_MODEL", "llama3.2") }
parser = OptionParser.new do |opts|
  opts.banner = "usage: bin/smoke_ollama.rb [--model MODEL] <prompt>"
  opts.on("--model MODEL", "Model identifier") { |m| options[:model] = m }
end
parser.parse!

prompt = ARGV.join(" ")
abort parser.banner if prompt.empty?

provider = Harnas::Providers::Ollama.new
request = { model: options[:model], messages: [{ role: "user", content: prompt }] }

begin
  response = provider.call(request)
rescue StandardError => e
  base_url = ENV.fetch("OLLAMA_BASE_URL", "http://localhost:11434/v1")
  warn "skip: Ollama is not reachable at #{base_url} (#{e.class})"
  exit 0
end

puts response.dig("choices", 0, "message", "content")
