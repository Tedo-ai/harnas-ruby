#!/usr/bin/env ruby
# frozen_string_literal: true

# examples/04-builtin-tools/run.rb
#
# Demonstrates wiring the shipped built-in tool library into a
# manifest-declared agent. The manifest references tools by the
# symbolic handler names under `harnas.builtin.*`; the façade
# resolves them via `Harnas::Tools::Builtin.handlers`.
#
# For the demo, a ScriptedProvider simulates an agent that:
#   1. calls list_dir on /tmp/harnas-demo
#   2. calls read_file on one of its entries
#   3. produces a final text reply

$LOAD_PATH.unshift File.expand_path("../../reference/lib", __dir__)

require "tmpdir"
require "harnas/agent"
require "harnas/tools/builtin"
require "harnas/conformance/scripted_provider"

MANIFEST_PATH = File.expand_path("manifest.json", __dir__)

# A throwaway directory so the demo is self-contained.
demo_dir = Dir.mktmpdir("harnas-builtin-demo-")
File.write(File.join(demo_dir, "alpha.txt"), "contents of alpha")
File.write(File.join(demo_dir, "beta.txt"),  "contents of beta")

scripted_responses = [
  {
    "content" => [
      { "type" => "tool_use", "id" => "call_ls",
        "name" => "list_dir", "input" => { "path" => demo_dir } }
    ],
    "stop_reason" => "tool_use",
    "usage" => { "input_tokens" => 18, "output_tokens" => 6 }
  },
  {
    "content" => [
      { "type" => "tool_use", "id" => "call_read",
        "name" => "read_file",
        "input" => { "path" => File.join(demo_dir, "alpha.txt") } }
    ],
    "stop_reason" => "tool_use",
    "usage" => { "input_tokens" => 32, "output_tokens" => 8 }
  },
  {
    "content" => [
      { "type" => "text",
        "text" => "The directory holds alpha.txt and beta.txt; alpha contains \"contents of alpha\"." }
    ],
    "stop_reason" => "end_turn",
    "usage" => { "input_tokens" => 44, "output_tokens" => 16 }
  }
]

agent = Harnas::Agent.from_manifest(
  MANIFEST_PATH,
  tool_handlers: Harnas::Tools::Builtin.handlers
)
agent.use_provider(
  Harnas::Conformance::ScriptedProvider.new(responses: scripted_responses)
)

response = agent.chat("what's in #{demo_dir}?")

puts "agent: #{agent.name}"
puts "---"
puts "assistant: #{response.text}"
puts "---"
puts "log (#{agent.log.size} events):"
agent.log.each do |event|
  detail =
    case event.type
    when :user_message, :assistant_message then event.payload[:text].to_s[0..70]
    when :tool_use
      "#{event.payload[:name]}(#{event.payload[:arguments].inspect})"
    when :tool_result
      (event.payload[:output] || event.payload[:error]).to_s[0..70]
    else ""
    end
  puts "  seq #{event.seq}  #{event.type.to_s.ljust(20)} #{detail}"
end
