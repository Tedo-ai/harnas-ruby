#!/usr/bin/env ruby
# frozen_string_literal: true

# Harnas CLI chat: an interactive REPL on top of Harnas::AgentLoop.
#
# Every user line drives one full agent-loop run against the configured
# Provider, possibly invoking the registered `echo` Tool, and prints
# the assistant's text reply. Type `exit`, `quit`, or Ctrl-D to leave.
#
# Usage:
#   bundle exec bin/chat.rb [--provider anthropic] [--no-tools] [--approve-tools]
#
#   --provider       only :anthropic is supported today
#   --no-tools       don't register the echo tool
#   --approve-tools  prompt for approval on each :tool_use via :pre_tool_use hook

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "optparse"
require "dotenv/load"

require "harnas/config"
require "harnas/session"
require "harnas/agent_loop"
require "harnas/events/user_message"
require "harnas/projections/anthropic"
require "harnas/providers/anthropic"
require "harnas/providers/anthropic_stream"
require "harnas/ingestors/anthropic"
require "harnas/tools/tool"
require "harnas/tools/registry"
require "harnas/tools/runner"
require "harnas/hooks"
require "harnas/observation"

options = { provider: :anthropic, tools: true, approve: false, stream: true }
OptionParser.new do |opts|
  opts.banner = "usage: bin/chat.rb [--provider PROVIDER] " \
                "[--no-tools] [--approve-tools] [--no-stream]"
  opts.on("--provider PROVIDER") { |p| options[:provider] = p.to_sym }
  opts.on("--no-tools", "Don't register the echo tool") { options[:tools] = false }
  opts.on("--approve-tools", "Prompt before each tool_use") { options[:approve] = true }
  opts.on("--no-stream", "Disable streaming (buffered request-response)") do
    options[:stream] = false
  end
  opts.on("-h", "--help") do
    puts opts
    exit
  end
end.parse!

unless options[:provider] == :anthropic
  warn "only --provider anthropic is supported right now"
  exit 1
end

config  = Harnas::Config.for_provider(:anthropic)
api_key = ENV.fetch("ANTHROPIC_API_KEY") do
  warn "error: ANTHROPIC_API_KEY is not set"
  exit 1
end

registry = Harnas::Tools::Registry.new
if options[:tools]
  registry.register(
    Harnas::Tools::Tool.new(
      name: "echo",
      description: "Echoes the given text back unchanged.",
      input_schema: {
        type: "object",
        properties: { text: { type: "string" } },
        required: ["text"]
      }
    ) { |args| args[:text].to_s }
  )
end

session    = Harnas::Session.create(metadata: { provider: :anthropic })
projection = Harnas::Projections::Anthropic.new(model: config.fetch(:model), registry: registry)
runner     = Harnas::Tools::Runner.new(registry)

stream_provider = if options[:stream]
                    Harnas::Providers::AnthropicStream.new(
                      api_key: api_key, api_version: config.fetch(:api_version)
                    )
                  end
buffered_provider = unless options[:stream]
                      Harnas::Providers::Anthropic.new(
                        api_key: api_key, api_version: config.fetch(:api_version)
                      )
                    end
buffered_ingestor = Harnas::Ingestors::Anthropic.new unless options[:stream]

# Stream printer: subscribe to Observation, render assistant_text_delta chunks live.
stream_state = { printing: false }
if options[:stream]
  Harnas::Observation.subscribe do |event_name, payload|
    next unless event_name == :event_appended

    case payload[:event].type
    when :assistant_turn_started
      print "\nbot> "
      stream_state[:printing] = true
    when :assistant_text_delta
      print(payload[:event].payload[:chunk])
      $stdout.flush
    when :assistant_turn_completed
      puts if stream_state[:printing]
      stream_state[:printing] = false
    end
  end
end

# Permission-prompt hook — a concrete, interactive :pre_tool_use handler.
if options[:approve]
  Harnas::Hooks.on(:pre_tool_use) do |tool_use:, **_|
    name = tool_use.payload[:name]
    args = tool_use.payload[:arguments]
    print "\n[approve tool_use] #{name}(#{args.inspect}) ? [y/N] "
    answer = $stdin.gets&.strip&.downcase
    answer == "y" ? { allow: true } : { allow: false, reason: "user declined" }
  end
end

# Pretty-print tool calls as they happen — a concrete :post_tool_use observer.
Harnas::Hooks.on(:post_tool_use) do |tool_use:, tool_result:, denied:, **_|
  name = tool_use.payload[:name]
  args = tool_use.payload[:arguments]
  if denied
    warn "  ✗ #{name}(#{args.inspect}) denied"
  elsif tool_result
    outcome = if tool_result.payload[:error]
                "✗ error: #{tool_result.payload[:error]}"
              else
                "✓ #{tool_result.payload[:output].inspect}"
              end
    warn "  → #{name}(#{args.inspect}) #{outcome}"
  end
end

tool_list = registry.size.positive? ? "(#{registry.names.join(", ")})" : "(no tools)"
puts "harnas chat · provider=#{options[:provider]} · tools=#{tool_list}"
puts "type 'exit' or 'quit' to leave, Ctrl-D to hang up"

loop do
  print "\nyou> "
  input = $stdin.gets
  break if input.nil?

  input = input.strip
  next  if input.empty?
  break if %w[exit quit].include?(input.downcase)

  session.log.append(
    type: :user_message,
    payload: Harnas::Events::UserMessage.new(text: input).to_h
  )

  agent = Harnas::AgentLoop.new(
    session: session,
    projection: projection,
    provider: buffered_provider,
    ingestor: buffered_ingestor,
    stream_provider: stream_provider,
    runner: runner,
    max_turns: 10
  )

  begin
    agent.run
  rescue Harnas::Providers::HTTPError => e
    warn "  [provider error: HTTP #{e.status}] #{e.body.inspect}"
    next
  rescue Harnas::Providers::Error => e
    warn "  [provider error] #{e.message}"
    next
  end

  next if options[:stream] # streaming already printed live; skip the buffered render

  final = session.log.reverse_each.find do |e|
    e.type == :assistant_message && !e.payload[:text].empty?
  end
  puts "\nbot> #{final&.payload&.fetch(:text) || "(no text response)"}"
end

puts "\nbye. #{session.log.size} events in session #{session.id}."
