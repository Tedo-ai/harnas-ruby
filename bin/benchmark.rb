#!/usr/bin/env ruby
# frozen_string_literal: true

# Benchmark runner: load canonical scenarios from
# spec/conformance/scenarios/ and compare each configured Strategy
# by running it through the deterministic CannedProvider. Prints the
# comparison table to stdout.
#
# Usage:
#   bundle exec bin/benchmark.rb [scenario-name ...]
#
# With no arguments, runs every scenario under
# spec/conformance/scenarios/. With one or more names, runs only
# those.

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "yaml"
require "harnas/benchmark/scenario"
require "harnas/benchmark/runner"
require "harnas/benchmark/report"
require "harnas/strategies/compaction/marker_tail"
require "harnas/strategies/compaction/token_marker_tail"

SCENARIOS_DIR = File.expand_path("../../spec/conformance/scenarios", __dir__)

STRATEGY_PACK = [
  {
    name: "no-compaction",
    install: ->(_session) {}
  },
  {
    name: "marker-tail-max6-keep3",
    install: lambda { |session|
      Harnas::Strategies::Compaction::MarkerTail.install(session, max_messages: 6, keep_recent: 3)
    }
  },
  {
    name: "marker-tail-max4-keep2",
    install: lambda { |session|
      Harnas::Strategies::Compaction::MarkerTail.install(session, max_messages: 4, keep_recent: 2)
    }
  },
  {
    name: "token-marker-tail-1000@50%",
    install: lambda { |session|
      Harnas::Strategies::Compaction::TokenMarkerTail.install(
        session,
        max_tokens: 1000, threshold: 0.5, keep_recent: 3
      )
    }
  }
].freeze

def load_scenario(path)
  data = YAML.safe_load_file(path)
  Harnas::Benchmark::Scenario.new(
    name: data["name"],
    description: data["description"].to_s,
    prompts: data["prompts"]
  )
end

selected = if ARGV.empty?
             Dir["#{SCENARIOS_DIR}/*.yml"]
           else
             ARGV.map do |n|
               "#{SCENARIOS_DIR}/#{n}.yml"
             end
           end

results = []
selected.each do |path|
  scenario = load_scenario(path)
  warn "── #{scenario.name}: #{scenario.prompts.size} prompts ──"

  STRATEGY_PACK.each do |strat|
    runner = Harnas::Benchmark::Runner.new
    results << runner.run(
      scenario: scenario,
      strategy_name: strat[:name],
      install_strategy: strat[:install]
    )
    warn "   #{strat[:name].ljust(20)} ok"
  end
end

puts
puts Harnas::Benchmark::Report.render(results)
puts
