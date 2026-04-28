# frozen_string_literal: true

module Harnas
  module Benchmark
    # A canonical benchmark scenario: a named, reproducible sequence
    # of user prompts (plus optional canned assistant responses) that
    # gets replayed against multiple strategy configurations for
    # comparison.
    #
    # Scenarios are deliberately small values — the scoring and
    # configuration happens in the Runner.
    Scenario = Data.define(:name, :description, :prompts, :canned_responses) do
      def initialize(name:, description:, prompts:, canned_responses: nil)
        raise ArgumentError, "name must be a non-empty String" \
          unless name.is_a?(String) && !name.empty?
        raise ArgumentError, "description must be a String" unless description.is_a?(String)
        raise ArgumentError, "prompts must be a non-empty Array of Strings" \
          unless prompts.is_a?(Array) && !prompts.empty? && prompts.all?(String)

        if canned_responses
          unless canned_responses.is_a?(Array) && canned_responses.all?(String)
            raise ArgumentError, "canned_responses must be an Array of Strings if present"
          end
          unless canned_responses.size == prompts.size
            raise ArgumentError, "canned_responses must have one entry per prompt"
          end
        end

        super
      end
    end
  end
end
