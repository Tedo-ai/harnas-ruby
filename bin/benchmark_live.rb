#!/usr/bin/env ruby
# frozen_string_literal: true

# Live benchmark: compare compaction strategies against real Anthropic
# on a canonical scenario. Answers the question Harnas was explicitly
# built to answer — "is the extra LLM call for LLM-summary compaction
# worth the input-token savings?"
#
# Requires ANTHROPIC_API_KEY. Costs a small amount of real money per
# run (~$1 depending on model and scenario length).
#
# Usage:
#   bundle exec bin/benchmark_live.rb [scenario-name]
#
# With no arguments, runs the long-conversation scenario.

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "yaml"
require "dotenv/load"
require "harnas/config"
require "harnas/benchmark/scenario"
require "harnas/benchmark/runner"
require "harnas/benchmark/report"
require "harnas/projections/anthropic"
require "harnas/providers/anthropic"
require "harnas/ingestors/anthropic"
require "harnas/strategies/compaction/marker_tail"
require "harnas/strategies/compaction/summary_tail"

SCENARIOS_DIR = File.expand_path("../../spec/conformance/scenarios", __dir__)

api_key = ENV.fetch("ANTHROPIC_API_KEY") do
  warn "error: ANTHROPIC_API_KEY is not set"
  exit 1
end

config     = Harnas::Config.for_provider(:anthropic)
model      = config.fetch(:model)
api_ver    = config.fetch(:api_version)
projection = Harnas::Projections::Anthropic.new(model: model)
provider   = Harnas::Providers::Anthropic.new(api_key: api_key, api_version: api_ver)
ingestor   = Harnas::Ingestors::Anthropic.new

# Three strategies on the same scenario. Editorial, not performance:
# each answers "what kind of memory does the agent have after
# compaction fires?" differently.
STRATEGY_PACK = [
  {
    name: "no-compaction",
    install: -> {}
  },
  {
    name: "marker-tail-max6-keep3",
    install: lambda {
      Harnas::Strategies::Compaction::MarkerTail.install(max_messages: 6, keep_recent: 3)
    }
  },
  {
    name: "summary-tail-max6-keep3",
    install: lambda {
      Harnas::Strategies::Compaction::SummaryTail.install(
        projection: Harnas::Projections::Anthropic.new(model: model),
        provider: Harnas::Providers::Anthropic.new(api_key: api_key, api_version: api_ver),
        ingestor: Harnas::Ingestors::Anthropic.new,
        max_messages: 6,
        keep_recent: 3
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

scenario_name = ARGV.first || "long-conversation"
path = "#{SCENARIOS_DIR}/#{scenario_name}.yml"

unless File.exist?(path)
  warn "scenario not found: #{path}"
  exit 1
end

scenario = load_scenario(path)
warn "── live benchmark: #{scenario.name} (#{scenario.prompts.size} prompts) ──"
warn "── model: #{model}   (each run costs real API tokens)"
warn ""

results = []
STRATEGY_PACK.each do |strat|
  runner = Harnas::Benchmark::Runner.new(
    provider: provider, projection: projection, ingestor: ingestor
  )
  started = Time.now
  result = runner.run(
    scenario: scenario,
    strategy_name: strat[:name],
    install_strategy: strat[:install]
  )
  elapsed = (Time.now - started).round(1)
  results << result
  warn "   #{strat[:name].ljust(28)} turns=#{result.turns} " \
       "in=#{result.total_input_tokens} out=#{result.total_output_tokens} " \
       "compactions=#{result.compactions} wall=#{elapsed}s"
end

puts
puts Harnas::Benchmark::Report.render(results)
puts
