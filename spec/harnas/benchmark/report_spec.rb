# frozen_string_literal: true

require "harnas/benchmark/report"
require "harnas/benchmark/runner"

RSpec.describe Harnas::Benchmark::Report do
  def make_result(**overrides)
    defaults = {
      scenario_name: "scen",
      strategy_name: "strat",
      turns: 3,
      compactions: 1,
      total_input_tokens: 500,
      total_output_tokens: 50,
      total_duration_ms: 42
    }
    Harnas::Benchmark::Runner::Result.new(**defaults, **overrides)
  end

  it "renders a header per scenario" do
    results = [make_result(scenario_name: "scen-a"), make_result(scenario_name: "scen-b")]
    out     = described_class.render(results)
    expect(out).to match(/scenario: scen-a/)
    expect(out).to match(/scenario: scen-b/)
  end

  it "includes the column headers turns / compacts / in_toks / out_toks / duration_ms" do
    out = described_class.render([make_result])
    expect(out).to match(/turns/)
    expect(out).to match(/compacts/)
    expect(out).to match(/in_toks/)
    expect(out).to match(/out_toks/)
    expect(out).to match(/duration_ms/)
  end

  it "renders each strategy's numbers" do
    results = [
      make_result(strategy_name: "no-compact", total_input_tokens: 1000),
      make_result(strategy_name: "snip-20",    total_input_tokens: 400)
    ]
    out = described_class.render(results)
    expect(out).to include("no-compact")
    expect(out).to include("snip-20")
    expect(out).to match(/1000/)
    expect(out).to match(/\b400\b/)
  end
end
