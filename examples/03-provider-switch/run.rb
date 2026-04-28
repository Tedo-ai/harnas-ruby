#!/usr/bin/env ruby
# frozen_string_literal: true

# examples/03-provider-switch/run.rb
#
# Demonstrates the core claim of the Harnas specification: the Log
# is sovereign and provider-agnostic. A conversation started against
# one projection/ingestor pair can be continued against another
# without touching the Log. This example drives the same Session
# across two different provider projections and prints the request
# body each would send for the next turn.

$LOAD_PATH.unshift File.expand_path("../../reference/lib", __dir__)

require "json"
require "harnas/agent"
require "harnas/projections/anthropic"
require "harnas/projections/openai"
require "harnas/projections/gemini"
require "harnas/conformance/scripted_provider"

MANIFEST_PATH = File.expand_path("manifest.json", __dir__)

agent = Harnas::Agent.from_manifest(MANIFEST_PATH)

# Swap in a ScriptedProvider so the example is deterministic.
agent.use_provider(
  Harnas::Conformance::ScriptedProvider.new(
    responses: [
      {
        "content" => [{ "type" => "text", "text" => "got it." }],
        "stop_reason" => "end_turn",
        "usage" => { "input_tokens" => 4, "output_tokens" => 2 }
      },
      {
        "content" => [{ "type" => "text", "text" => "still got it." }],
        "stop_reason" => "end_turn",
        "usage" => { "input_tokens" => 8, "output_tokens" => 3 }
      }
    ]
  )
)

agent.chat("my name is Alice")
agent.chat("remember my name")

# The Log now contains four events — two user messages and two
# assistant messages — completely provider-agnostic. We can render
# it into the wire format any of the three providers expects without
# changing the Log itself.
projections = {
  anthropic: Harnas::Projections::Anthropic.new(model: "claude-example"),
  openai: Harnas::Projections::OpenAI.new(model: "gpt-example"),
  gemini: Harnas::Projections::Gemini.new(model: "gemini-example")
}

puts "log (#{agent.log.size} events):"
agent.log.each do |event|
  preview =
    case event.type
    when :user_message, :assistant_message then event.payload[:text].to_s[0..60]
    else ""
    end
  puts "  seq #{event.seq}  #{event.type.to_s.ljust(20)} #{preview}"
end
puts

puts "same Log, three wire shapes:"
projections.each do |name, projection|
  request = projection.call(agent.log)
  # Print just the shape of messages[] / contents[] — the part that
  # differs per provider — to keep the output compact.
  messages = request[:messages] || request[:contents]
  puts
  puts "=== #{name} ==="
  puts JSON.pretty_generate(messages)
end
