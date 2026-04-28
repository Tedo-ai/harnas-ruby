#!/usr/bin/env ruby
# frozen_string_literal: true

# End-to-end tool round-trip smoke: build a Session with an `echo`
# Tool registered, send a prompt that asks the model to use it, and
# run the agent loop:
#
#   Log → Projection (incl. tools) → Provider → Ingestor → Log
#     ↓  (stop_reason == :tool_use? run pending :tool_use events)
#   Runner executes each pending Tool → appends :tool_result
#     ↓  (loop again with the updated Log)
#
# Stops when the assistant's stop_reason is :end_turn (or when there
# are no more pending tool_uses, or at MAX_TURNS).
#
# Usage:
#   bundle exec bin/smoke_tool.rb [--record DIR] [--turns N] [<prompt>]
#
#   --record DIR   write each turn's request.json and response.json to
#                  DIR/turn-N-request.json / DIR/turn-N-response.json
#   --turns N      cap the agent loop at N turns (default 5)
#
# Anthropic-only for now; OpenAI and Gemini fan out in a later phase.

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "fileutils"
require "optparse"
require "dotenv/load"
require "json"

require "harnas/config"
require "harnas/session"
require "harnas/events/user_message"
require "harnas/projections/anthropic"
require "harnas/providers/anthropic"
require "harnas/ingestors/anthropic"
require "harnas/tools/tool"
require "harnas/tools/registry"
require "harnas/tools/runner"

MAX_TURNS_DEFAULT = 5
DEFAULT_PROMPT = "Please call the echo tool with text set to 'hello from harnas'. " \
                 "After the tool returns, reply with exactly the word: done."

def pending_tool_uses(log)
  fulfilled = log.each_with_object(Set.new) do |e, set|
    set << e.payload[:tool_use_id] if e.type == :tool_result
  end
  log.select { |e| e.type == :tool_use && !fulfilled.include?(e.payload[:id]) }
end

def record_turn(dir, turn, request, response)
  File.write(File.join(dir, "turn-#{turn}-request.json"),
             "#{JSON.pretty_generate(request)}\n")
  File.write(File.join(dir, "turn-#{turn}-response.json"),
             "#{JSON.pretty_generate(response)}\n")
end

options = { record: nil, turns: MAX_TURNS_DEFAULT }
OptionParser.new do |opts|
  opts.banner = "usage: bin/smoke_tool.rb [--record DIR] [--turns N] [<prompt>]"
  opts.on("--record DIR", "Write each turn's request/response JSON to DIR") do |d|
    options[:record] = d
  end
  opts.on("--turns N", Integer,
          "Cap the agent loop at N turns (default #{MAX_TURNS_DEFAULT})") do |n|
    options[:turns] = n
  end
  opts.on("-h", "--help") do
    puts opts
    exit
  end
end.parse!

prompt = ARGV.join(" ")
prompt = DEFAULT_PROMPT if prompt.empty?

# One-line registered tool: echo its text back.
registry = Harnas::Tools::Registry.new
registry.register(
  Harnas::Tools::Tool.new(
    name: "echo",
    description: "Echoes the given text back unchanged.",
    input_schema: {
      type: "object",
      properties: { text: { type: "string", description: "the text to echo back" } },
      required: ["text"]
    }
  ) { |args| args[:text].to_s }
)

config  = Harnas::Config.for_provider(:anthropic)
api_key = ENV.fetch("ANTHROPIC_API_KEY") do
  warn "error: ANTHROPIC_API_KEY is not set"
  exit 1
end

session    = Harnas::Session.create(metadata: { provider: :anthropic })
projection = Harnas::Projections::Anthropic.new(model: config.fetch(:model), registry: registry)
provider   = Harnas::Providers::Anthropic.new(api_key: api_key,
                                              api_version: config.fetch(:api_version))
ingestor   = Harnas::Ingestors::Anthropic.new
runner     = Harnas::Tools::Runner.new(registry)

session.log.append(
  type: :user_message,
  payload: Harnas::Events::UserMessage.new(text: prompt).to_h
)

FileUtils.mkdir_p(options[:record]) if options[:record]

last_assistant = nil
(1..options[:turns]).each do |turn|
  warn "── turn #{turn} ──"

  request  = projection.call(session.log)
  response = provider.call(request)

  record_turn(options[:record], turn, request, response) if options[:record]

  ingestor.call(response).each { |e| session.log.append(**e) }

  last_assistant = session.log.reverse_each.find { |e| e.type == :assistant_message }
  stop = last_assistant.payload[:stop_reason]
  warn "  assistant stop_reason=#{stop}"

  break if stop != :tool_use

  pending = pending_tool_uses(session.log)
  if pending.empty?
    warn "  stop_reason=:tool_use but no pending :tool_use events; stopping"
    break
  end

  pending.each do |tu|
    warn "  invoking #{tu.payload[:name]}(#{tu.payload[:arguments].inspect})"
    runner.run(tu, into_log: session.log)
  end
end

final_text = session.log.reverse_each.find do |e|
  e.type == :assistant_message && !e.payload[:text].empty?
end&.payload&.fetch(:text)

puts final_text || "(no final assistant text)"

warn "── session #{session.id} ─ #{session.log.size} events"
session.log.each do |e|
  info =
    case e.type
    when :user_message      then %("#{e.payload[:text][0, 40]}")
    when :assistant_message then ":#{e.payload[:stop_reason]} \"#{e.payload[:text][0, 40]}\""
    when :tool_use          then "#{e.payload[:name]}(#{e.payload[:arguments].inspect})"
    when :tool_result       then "-> \"#{(e.payload[:output] || e.payload[:error])[0, 40]}\""
    else                         e.payload.inspect[0, 40]
    end
  warn "  seq=#{e.seq} #{e.type.to_s.ljust(18)} #{info}"
end
