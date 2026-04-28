#!/usr/bin/env ruby
# frozen_string_literal: true

# examples/01-hello-world/run.rb
#
# The minimum runnable Harnas agent. Loads a manifest, sends one
# user message, prints the assistant's reply. Runs against the mock
# provider by default — no API keys required.

$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)

require "harnas/agent"

MANIFEST_PATH = File.expand_path("manifest.json", __dir__)

agent    = Harnas::Agent.from_manifest(MANIFEST_PATH)
response = agent.chat("hello, are you there?")

puts "agent: #{agent.name}"
puts "model: mock"
puts "---"
puts "user:      hello, are you there?"
puts "assistant: #{response.text}"
puts "stop:      #{response.stop_reason}"
puts "---"
puts "log has #{agent.log.size} events:"
agent.log.each do |event|
  puts "  seq #{event.seq} · #{event.type}"
end
