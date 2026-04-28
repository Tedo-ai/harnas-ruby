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
#   bundle exec bin/conformance.rb [fixture-name ...]
#
# With no arguments, runs every fixture. With one or more names,
# runs only those.

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "json"
require "harnas/conformance/runner"

# Resolution order for the Harnas spec's conformance fixtures:
#   1. HARNAS_SPEC env var pointing at a checkout of Tedo-ai/harnas
#   2. ../harnas/conformance/agents (sibling clone — coordinator layout)
#   3. ../../spec/conformance/agents (legacy monorepo internal layout)
FIXTURES_DIR =
  if ENV["HARNAS_SPEC"]
    File.join(ENV["HARNAS_SPEC"], "conformance", "agents")
  elsif File.directory?(File.expand_path("../../harnas/conformance/agents", __dir__))
    File.expand_path("../../harnas/conformance/agents", __dir__)
  else
    File.expand_path("../../spec/conformance/agents", __dir__)
  end

unless File.directory?(FIXTURES_DIR)
  warn "no fixtures directory at #{FIXTURES_DIR}"
  exit 1
end

selected = if ARGV.empty?
             Dir.children(FIXTURES_DIR).select do |name|
               File.directory?(File.join(FIXTURES_DIR, name))
             end.sort
           else
             ARGV
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
puts "#{results.size} fixtures · #{results.size - failed} passed · #{failed} failed"

exit 1 if failed.positive?
