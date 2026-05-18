# frozen_string_literal: true

module Harnas
  module Strategies
    module Guard
      class CostBudget
        def self.install(session = nil, max_input_tokens: nil, max_output_tokens: nil)
          new(max_input_tokens: max_input_tokens,
              max_output_tokens: max_output_tokens).install(session&.hooks || Hooks)
        end

        def initialize(max_input_tokens: nil, max_output_tokens: nil)
          @max_input_tokens = max_input_tokens
          @max_output_tokens = max_output_tokens
        end

        def install(hooks = Hooks)
          handler = method(:on_pre_projection)
          hooks.on(:pre_projection, handler)
          handler
        end

        def on_pre_projection(session:, **_)
          input, output = totals(session)
          return if within_budget?(input, output)

          session.log.append(
            type: :runtime_error,
            payload: {
              source: "strategy", handler: "guard/cost_budget",
              error_class: "Harnas::BudgetExceeded", message: "budget_exceeded",
              reason: "budget_exceeded", input_tokens: input,
              max_input_tokens: @max_input_tokens, output_tokens: output,
              max_output_tokens: @max_output_tokens, terminal: true
            }
          )
        end

        private

        def totals(session)
          session.log.each_with_object([0, 0]) do |event, total|
            next unless event.type == :assistant_message

            usage = event.payload[:usage] || {}
            total[0] += usage[:input_tokens].to_i
            total[1] += usage[:output_tokens].to_i
          end
        end

        def within_budget?(input, output)
          (@max_input_tokens.nil? || input <= @max_input_tokens) &&
            (@max_output_tokens.nil? || output <= @max_output_tokens)
        end
      end
    end
  end
end
