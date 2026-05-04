# frozen_string_literal: true

module Harnas
  module Strategies
    # Shared helper for strategy invocation Observation events.
    module Observation
      def observe_strategy(session, name:, hook_point:)
        before = session.log.size
        session.observation.emit(:strategy_started, name: name, hook_point: hook_point)
        result = yield
        effect = strategy_effect(result, before, session.log.size)
        session.observation.emit(
          :strategy_completed,
          name: name,
          hook_point: hook_point,
          effect: effect
        )
        result
      rescue StandardError
        session.observation.emit(
          :strategy_completed,
          name: name,
          hook_point: hook_point,
          effect: "error"
        )
        raise
      end

      private

      def strategy_effect(result, before_size, after_size)
        return "mutated" if after_size > before_size
        return "refused" if result.is_a?(Hash) && result[:allow] == false

        "noop"
      end
    end
  end
end
