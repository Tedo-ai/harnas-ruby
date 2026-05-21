#!/usr/bin/env ruby
# frozen_string_literal: true

# Conformance runner: replays every agent-level fixture under
# spec/conformance/agents/ against the reference Harnas
# implementation and diffs the resulting Log against
# expected-log.jsonl.
#
# A passing run means: this implementation, when given each
# fixture's (manifest + provider-script + user inputs), produced
# the Log recorded in expected-log.jsonl. Any other spec-conformant
# implementation — Ruby, Python, Go, TypeScript, whatever — that
# also passes every fixture is by definition Harnas-conformant on
# these cases.
#
# Usage:
#   bundle exec bin/conformance.rb [--fixtures-from PATH] [fixture-name ...]
#
# With no arguments, runs every fixture. With one or more names,
# runs only those.

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "json"
require "harnas/conformance/runner"

fixtures_from = nil
remaining = []
until ARGV.empty?
  arg = ARGV.shift
  if arg == "--fixtures-from"
    fixtures_from = ARGV.shift or abort "--fixtures-from requires a path"
  else
    remaining << arg
  end
end

# Resolution order for the Harnas spec's conformance fixtures:
SPEC_ROOT =
  if fixtures_from
    fixtures_from
  elsif ENV["HARNAS_SPEC"]
    ENV["HARNAS_SPEC"]
  elsif File.directory?(File.expand_path("../../harnas/conformance/agents", __dir__))
    File.expand_path("../../harnas", __dir__)
  else
    File.expand_path("../../spec", __dir__)
  end

FIXTURES_DIR = File.join(SPEC_ROOT, "conformance", "agents")

unless File.directory?(FIXTURES_DIR)
  warn "no fixtures directory at #{FIXTURES_DIR}"
  exit 1
end

selected = if remaining.empty?
             Dir.children(FIXTURES_DIR).select do |name|
               File.directory?(File.join(FIXTURES_DIR, name))
             end.sort
           else
             remaining
           end

if selected.empty?
  warn "no fixtures to run"
  exit 0
end

results = selected.map do |name|
  dir = File.join(FIXTURES_DIR, name)
  unless File.directory?(dir)
    warn "no such fixture: #{name}"
    exit 1
  end
  Harnas::Conformance::Runner.run(dir)
end

results.each do |r|
  if r.passed
    puts "  ✓  #{r.summary}"
  else
    puts "  ✗  #{r.summary}"
    puts
    puts "    expected:"
    puts JSON.pretty_generate(r.diff[:expected]).lines.map { |l| "      #{l}" }.join
    puts
    puts "    actual:"
    puts JSON.pretty_generate(r.diff[:actual]).lines.map { |l| "      #{l}" }.join
    puts
  end
end

failed = results.count { |r| !r.passed }
puts
version = Harnas::Conformance::Runner.fixture_version(SPEC_ROOT)
suffix = version ? " against fixtures v#{version}" : ""
puts "#{results.size} fixtures · #{results.size - failed} passed · #{failed} failed#{suffix}"

exit 1 if failed.positive?
