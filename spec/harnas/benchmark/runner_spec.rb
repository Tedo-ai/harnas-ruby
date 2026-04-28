# frozen_string_literal: true

require "harnas/benchmark/runner"
require "harnas/benchmark/scenario"
require "harnas/strategies/compaction/marker_tail"

RSpec.describe Harnas::Benchmark::Runner do
  let(:runner) { described_class.new }

  let(:short_scenario) do
    Harnas::Benchmark::Scenario.new(
      name: "short",
      description: "Three user prompts, no compaction needed.",
      prompts: ["hi", "how are you?", "ok bye"]
    )
  end

  let(:long_scenario) do
    Harnas::Benchmark::Scenario.new(
      name: "long",
      description: "Many user prompts to exercise context growth.",
      prompts: Array.new(12) { |i| "user message number #{i}" }
    )
  end

  describe "#run with no strategy installed" do
    it "returns a Result with turns matching prompts count" do
      result = runner.run(scenario: short_scenario, strategy_name: "none")
      expect(result.turns).to eq(3)
      expect(result.compactions).to eq(0)
    end

    it "records non-zero total_input_tokens" do
      result = runner.run(scenario: short_scenario, strategy_name: "none")
      expect(result.total_input_tokens).to be > 0
    end
  end

  describe "#run with MarkerTail strategy installed" do
    it "records compactions when the threshold is exceeded" do
      result = runner.run(
        scenario: long_scenario,
        strategy_name: "marker-tail-5",
        install_strategy: lambda { |session|
          Harnas::Strategies::Compaction::MarkerTail.install(session, max_messages: 5,
                                                                      keep_recent: 2)
        }
      )
      expect(result.compactions).to be > 0
    end

    it "carries the strategy_name through to the Result" do
      result = runner.run(
        scenario: long_scenario,
        strategy_name: "marker-tail-5",
        install_strategy: lambda { |session|
          Harnas::Strategies::Compaction::MarkerTail.install(session, max_messages: 5,
                                                                      keep_recent: 2)
        }
      )
      expect(result.strategy_name).to eq("marker-tail-5")
    end
  end

  describe "strategy comparison (the benchmark payoff)" do
    it "produces fewer input tokens with MarkerTail than without on the long scenario" do
      none = runner.run(scenario: long_scenario, strategy_name: "none")

      runner2 = described_class.new # fresh runner so no state leaks
      marker_tail = runner2.run(
        scenario: long_scenario,
        strategy_name: "marker-tail-4",
        install_strategy: lambda { |session|
          Harnas::Strategies::Compaction::MarkerTail.install(session, max_messages: 4,
                                                                      keep_recent: 2)
        }
      )

      expect(marker_tail.total_input_tokens).to be < none.total_input_tokens
      expect(marker_tail.compactions).to be > 0
      expect(none.compactions).to eq(0)
    end
  end
end
