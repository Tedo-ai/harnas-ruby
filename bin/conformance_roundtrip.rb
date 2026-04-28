#!/usr/bin/env ruby
# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "json"
require "optparse"
require "harnas/session"
require "harnas/conformance/runner"

options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: bin/conformance_roundtrip.rb --fixture NAME --phase 1|2 " \
                "[--save PATH] [--load PATH] [--check PATH]"
  opts.on("--fixture NAME") { |value| options[:fixture] = value }
  opts.on("--phase PHASE", Integer) { |value| options[:phase] = value }
  opts.on("--save PATH") { |value| options[:save] = value }
  opts.on("--load PATH") { |value| options[:load] = value }
  opts.on("--check PATH") { |value| options[:check] = value }
end.parse!

def spec_root
  return ENV.fetch("HARNAS_SPEC") if ENV["HARNAS_SPEC"]

  sibling = File.expand_path("../../harnas", __dir__)
  return sibling if File.directory?(File.join(sibling, "conformance", "round-trips"))

  File.expand_path("../../spec", __dir__)
end

def read_json(path)
  JSON.parse(File.read(path))
end

unless options[:fixture] && options[:phase]
  warn "missing --fixture or --phase"
  exit 1
end

fixture_dir = File.join(spec_root, "conformance", "round-trips", options.fetch(:fixture))
manifest = read_json(File.join(fixture_dir, "manifest.json"))
script = read_json(File.join(fixture_dir, "phase-#{options.fetch(:phase)}-provider-script.json"))
inputs = read_json(File.join(fixture_dir, "phase-#{options.fetch(:phase)}-inputs.json"))

case options.fetch(:phase)
when 1
  abort "--save is required for phase 1" unless options[:save]

  session = Harnas::Conformance::Runner.run_session(manifest, script, inputs)
  session.save(options.fetch(:save))
  puts "saved #{options.fetch(:fixture)} (#{session.log.size} events)"
when 2
  abort "--load is required for phase 2" unless options[:load]
  abort "--check is required for phase 2" unless options[:check]

  session = Harnas::Session.load(options.fetch(:load))
  session = Harnas::Conformance::Runner.run_session(manifest, script, inputs, session: session)
  actual = Harnas::Conformance::Runner.serialize_log(session.log)
  expected = Harnas::Conformance::Runner.load_expected(options.fetch(:check))
  diff = Harnas::Conformance::Runner.first_mismatch(actual, expected)
  if diff
    warn "round-trip mismatch at seq #{diff[:at_seq]}"
    warn "expected: #{JSON.pretty_generate(diff[:expected])}"
    warn "actual: #{JSON.pretty_generate(diff[:actual])}"
    exit 1
  end
  puts "checked #{options.fetch(:fixture)} (#{actual.size} events)"
else
  warn "unknown phase: #{options.fetch(:phase)}"
  exit 1
end
