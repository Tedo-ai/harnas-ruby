#!/usr/bin/env ruby
# frozen_string_literal: true

# examples/02-tool-calling/run.rb
#
# A Harnas agent that registers one tool (get_current_time) and
# drives the full tool-call round-trip: assistant requests the tool,
# the harness dispatches it, the tool result is appended to the Log,
# and the assistant synthesizes a final text reply.
#
# Uses a ScriptedProvider so the example is deterministic — no API
# keys required. To run against a live provider, change the manifest's
# provider.kind and pass an api_key to Agent.from_manifest.

$LOAD_PATH.unshift File.expand_path("../../reference/lib", __dir__)

require "time"
require "harnas/agent"
require "harnas/conformance/scripted_provider"

MANIFEST_PATH = File.expand_path("manifest.json", __dir__)

# The tool implementation is plain Ruby; the manifest declares the
# symbolic handler name "examples.get_current_time" which we resolve
# to this lambda when loading.
tool_handlers = {
  "examples.get_current_time" => ->(_args) { Time.now.utc.iso8601 }
}

# Pre-recorded provider responses that model the canonical tool-call
# round-trip (Anthropic-shaped here because the "mock" provider kind
# uses the Anthropic projection/ingestor pair).
scripted_responses = [
  {
    "content" => [
      {
        "type" => "tool_use",
        "id" => "toolu_example",
        "name" => "get_current_time",
        "input" => {}
      }
    ],
    "stop_reason" => "tool_use",
    "usage" => { "input_tokens" => 12, "output_tokens" => 5 }
  },
  {
    "content" => [
      { "type" => "text", "text" => "The current time is now available in the Log." }
    ],
    "stop_reason" => "end_turn",
    "usage" => { "input_tokens" => 28, "output_tokens" => 11 }
  }
]

agent = Harnas::Agent.from_manifest(MANIFEST_PATH, tool_handlers: tool_handlers)

# Swap the loaded Manifest's provider for a ScriptedProvider so the
# example runs deterministically without network access.
agent.use_provider(
  Harnas::Conformance::ScriptedProvider.new(responses: scripted_responses)
)

response = agent.chat("what time is it?")

puts "agent: #{agent.name}"
puts "---"
puts "user:      what time is it?"
puts "assistant: #{response.text}"
puts "stop:      #{response.stop_reason}"
puts "---"
puts "log (#{agent.log.size} events):"
agent.log.each do |event|
  detail =
    case event.type
    when :user_message, :assistant_message
      event.payload[:text].to_s[0..60]
    when :tool_use
      "#{event.payload[:name]}(#{event.payload[:arguments]})"
    when :tool_result
      event.payload[:output].to_s[0..60]
    else
      ""
    end
  puts "  seq #{event.seq}  #{event.type.to_s.ljust(20)} #{detail}"
end
