# frozen_string_literal: true

module Harnas
  module Benchmark
    # Renders a collection of Runner::Results as a plaintext comparison
    # table grouped by scenario. Each scenario becomes one block;
    # rows are strategies and columns are metrics.
    module Report
      def self.render(results)
        by_scenario = results.group_by(&:scenario_name)
        by_scenario.map { |name, rows| render_scenario(name, rows) }.join("\n\n")
      end

      def self.render_scenario(scenario_name, rows)
        header = "scenario: #{scenario_name}"
        strategy_col_width = [rows.map { |r| r.strategy_name.length }.max, 12].max

        lines = [header, "-" * header.length]
        lines << format_header_row(strategy_col_width)
        lines << format_divider(strategy_col_width)
        rows.each { |r| lines << format_row(r, strategy_col_width) }
        lines.join("\n")
      end

      def self.format_header_row(width)
        format("  %-#{width}s  %7s  %8s  %8s  %10s  %11s",
               "strategy", "turns", "compacts", "in_toks", "out_toks", "duration_ms")
      end

      def self.format_divider(width)
        format("  %-#{width}s  %7s  %8s  %8s  %10s  %11s",
               "-" * width, "-------", "--------", "--------", "----------", "-----------")
      end

      def self.format_row(result, width)
        format("  %-#{width}s  %7d  %8d  %8d  %10d  %11d",
               result.strategy_name,
               result.turns,
               result.compactions,
               result.total_input_tokens,
               result.total_output_tokens,
               result.total_duration_ms)
      end
    end
  end
end
