# frozen_string_literal: true

require "harnas/observation"
require "harnas/hooks"
require "harnas/session"
require "harnas/agent_loop"
require "harnas/events/user_message"
require "harnas/projections/anthropic"
require "harnas/ingestors/anthropic"
require "harnas/benchmark/canned_provider"

module Harnas
  module Benchmark
    # Runs a Scenario under a specific Strategy configuration and
    # returns a Result value object carrying the metrics observed
    # during the run.
    #
    # The Runner is deliberately single-threaded and synchronous:
    # each (scenario × strategy) cell runs in isolation, Observation
    # is reset between runs, Hooks are scoped per run. This keeps
    # results reproducible and comparable.
    class Runner
      Result = Data.define(
        :scenario_name, :strategy_name,
        :turns, :compactions, :total_input_tokens, :total_output_tokens,
        :total_duration_ms
      )

      def initialize(provider: CannedProvider.new,
                     projection: Projections::Anthropic.new(model: "bench-model"),
                     ingestor: Ingestors::Anthropic.new)
        @provider   = provider
        @projection = projection
        @ingestor   = ingestor
      end

      def run(scenario:, strategy_name:, install_strategy: -> {})
        collector = Observation::Collector.new
        result    = nil

        Observation.reset!
        Harnas::Hooks.scoped do
          Observation.subscribe(collector)
          install_strategy.call

          session = Session.create
          drive_scenario(scenario, session)

          result = build_result(scenario, strategy_name, collector)
        end

        result
      ensure
        Observation.reset!
      end

      private

      def drive_scenario(scenario, session)
        scenario.prompts.each do |prompt|
          session.log.append(
            type: :user_message,
            payload: Events::UserMessage.new(text: prompt).to_h
          )

          AgentLoop.new(
            session: session,
            projection: @projection,
            provider: @provider,
            ingestor: @ingestor,
            max_turns: 3
          ).run
        end
      end

      def build_result(scenario, strategy_name, collector)
        tokens = collector.of(:tokens_consumed).map { |(_, p)| p }
        Result.new(
          scenario_name: scenario.name,
          strategy_name: strategy_name,
          turns: collector.count(:provider_called),
          compactions: collector.of(:event_appended)
                       .count { |(_, p)| p[:event].type == :compact },
          total_input_tokens: tokens.sum { |p| p[:input_tokens] },
          total_output_tokens: tokens.sum { |p| p[:output_tokens] },
          total_duration_ms: collector.of(:provider_responded)
                             .sum { |(_, p)| p[:duration_ms] }
        )
      end
    end
  end
end
