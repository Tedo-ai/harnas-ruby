#!/usr/bin/env ruby
# frozen_string_literal: true

# examples/05-codebase-qa/run.rb
#
# First LIVE example. Drives a real provider end-to-end with:
#   - a system prompt
#   - the full built-in tool library (read_file, list_dir, glob,
#     grep, edit_file)
#   - StaleReadGuard wrapping read/edit/write
#   - MarkerTail compaction (from the manifest)
#
# Requires API keys in .env or the environment — the manifest loader
# resolves the right key for the selected provider. Pick a provider
# via --provider; the default is anthropic.
#
# Usage:
#   bundle exec ruby examples/05-codebase-qa/run.rb \
#     [--provider anthropic|openai|gemini] \
#     [--model MODEL] \
#     "your question here"

$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)

require "dotenv"
Dotenv.load(File.expand_path("../../.env", __dir__))

require "optparse"
require "json"
require "harnas/agent"
require "harnas/config"
require "harnas/observation"
require "harnas/tools/builtin"
require "harnas/tools/middleware/stale_read_guard"

options = { provider: "anthropic", model: nil, save: :default, no_save: false }
parser = OptionParser.new do |op|
  op.on("--provider KIND") { |v| options[:provider] = v }
  op.on("--model MODEL")   { |v| options[:model]    = v }
  op.on("--save PATH")     { |v| options[:save]     = v }
  op.on("--no-save")       { options[:no_save] = true }
end
prompt_args = parser.parse(ARGV)

if prompt_args.empty?
  warn "usage: run.rb [--provider KIND] [--model MODEL] \"your question\""
  exit 1
end
prompt = prompt_args.join(" ")

manifest_path = File.expand_path("manifest.json", __dir__)
manifest = JSON.parse(File.read(manifest_path))
manifest["provider"]["kind"] = options[:provider]

# Model resolution: --model > <PROVIDER>_MODEL env var > config default.
# The manifest's own model field is ignored when --provider switches the kind,
# so a manifest written for one provider isn't accidentally projected to another.
resolved_model =
  options[:model] ||
  ENV["#{options[:provider].upcase}_MODEL"] ||
  Harnas::Config.for_provider(options[:provider].to_sym).fetch(:model)
manifest["provider"]["model"] = resolved_model

agent = Harnas::Agent.from_manifest(
  manifest,
  tool_handlers: Harnas::Tools::Builtin.handlers
)

# Wrap file-touching handlers with the Log-sourced StaleReadGuard.
guard = Harnas::Tools::Middleware::StaleReadGuard.new(
  log: agent.session.log, strict: true
)
wrapped = Harnas::Tools::Builtin.handlers.dup
wrapped["harnas.builtin.read_file"]  = guard.wrap_read(wrapped["harnas.builtin.read_file"])
wrapped["harnas.builtin.edit_file"]  = guard.wrap_edit(wrapped["harnas.builtin.edit_file"])
wrapped["harnas.builtin.write_file"] = guard.wrap_write(wrapped["harnas.builtin.write_file"])
agent.registry.tools.each do |tool|
  handler_name = "harnas.builtin.#{tool.name}"
  next unless wrapped.key?(handler_name)

  tool.instance_variable_set(:@block, wrapped[handler_name])
end

puts "agent:    #{agent.name}"
puts "provider: #{options[:provider]} / #{manifest["provider"]["model"]}"
puts "prompt:   #{prompt}"
puts "---"

# Stash the most recent provider request so we can print it on failure.
last_request = nil
agent.session.observation.subscribe(
  ->(ev, payload) { last_request = payload[:request] if ev == :provider_called }
)

def save_session(agent, options)
  return if options[:no_save]

  save_path =
    if options[:save] == :default
      runs_dir = File.expand_path("runs", __dir__)
      Dir.mkdir(runs_dir) unless File.directory?(runs_dir)
      stamp = Time.now.utc.strftime("%Y%m%d-%H%M%S")
      suffix = options[:failed] ? "-failed" : ""
      File.join(runs_dir, "#{options[:provider]}-#{stamp}#{suffix}.jsonl")
    else
      options[:save]
    end
  agent.session.save(save_path)
  puts "saved: #{save_path}"
end

started = Time.now
begin
  response = agent.chat(prompt)
rescue Harnas::Providers::HTTPError => e
  puts "PROVIDER ERROR  status=#{e.status}"
  puts "body:    #{JSON.pretty_generate(e.body)}"
  puts
  puts "request that triggered it:"
  puts JSON.pretty_generate(last_request) if last_request
  puts
  options[:failed] = true
  save_session(agent, options)
  exit 2
end
elapsed = (Time.now - started).round(1)

puts "assistant: #{response.text}"
puts "---"
puts "stop: #{response.stop_reason}  ·  elapsed: #{elapsed}s  ·  log size: #{agent.log.size}"
puts
save_session(agent, options)

puts "log trace:"
agent.log.each do |event|
  detail =
    case event.type
    when :user_message, :assistant_message
      event.payload[:text].to_s[0..80]
    when :tool_use
      "#{event.payload[:name]}(#{event.payload[:arguments].inspect[0..60]})"
    when :tool_result
      (event.payload[:output] || event.payload[:error]).to_s[0..80]
    when :annotation
      "#{event.payload[:kind]} #{event.payload[:data].inspect[0..60]}"
    when :compact
      "replaces=#{event.payload[:replaces].inspect[0..40]}"
    else
      ""
    end
  puts "  seq #{event.seq.to_s.rjust(2)}  #{event.type.to_s.ljust(20)} #{detail}"
end
