# frozen_string_literal: true

module Harnas
  module Usage
    module_function

    def normalize(raw) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      usage = raw.is_a?(Hash) ? stringify(raw) : {}
      return canonical(usage) if canonical?(usage)

      input = int_value(
        first_present(usage["input_tokens"], usage["prompt_tokens"], usage["promptTokenCount"])
      )
      output = int_value(
        first_present(
          usage["output_tokens"], usage["completion_tokens"], usage["candidatesTokenCount"]
        )
      )
      total = int_value(first_present(usage["total_tokens"], usage["totalTokenCount"]))
      total = input + output if total.zero? && (input.positive? || output.positive?)

      {
        input_tokens: input,
        output_tokens: output,
        total_tokens: total,
        cache_read_input_tokens: optional_int(
          first_present(dig(usage, "prompt_tokens_details", "cached_tokens"),
                        dig(usage, "input_token_details", "cache_read"),
                        usage["cache_read_input_tokens"])
        ),
        cache_write_input_tokens: optional_int(
          first_present(
            dig(usage, "cache_creation", "input_tokens"), usage["cache_write_input_tokens"]
          )
        ),
        reasoning_tokens: optional_int(
          first_present(
            dig(usage, "completion_tokens_details", "reasoning_tokens"), usage["reasoning_tokens"]
          )
        ),
        provider_raw: usage.empty? ? nil : usage,
        provenance: usage.empty? ? "unavailable" : "provider_reported"
      }
    end

    def canonical?(usage)
      %w[
        input_tokens output_tokens total_tokens provider_raw provenance
      ].all? { |key| usage.key?(key) }
    end

    def canonical(usage)
      {
        input_tokens: int_value(usage["input_tokens"]),
        output_tokens: int_value(usage["output_tokens"]),
        total_tokens: int_value(usage["total_tokens"]),
        cache_read_input_tokens: optional_int(usage["cache_read_input_tokens"]),
        cache_write_input_tokens: optional_int(usage["cache_write_input_tokens"]),
        reasoning_tokens: optional_int(usage["reasoning_tokens"]),
        provider_raw: usage["provider_raw"],
        provenance: usage["provenance"].to_s
      }
    end

    def stringify(value)
      value.each_with_object({}) { |(key, val), out| out[key.to_s] = stringify_value(val) }
    end

    def stringify_value(value)
      case value
      when Hash then stringify(value)
      when Array then value.map { |item| stringify_value(item) }
      else value
      end
    end

    def first_present(*values)
      values.find { |value| !value.nil? }
    end

    def dig(value, *keys)
      keys.reduce(value) do |current, key|
        current.is_a?(Hash) ? current[key] : nil
      end
    end

    def optional_int(value)
      value.nil? ? nil : int_value(value)
    end

    def int_value(value)
      value.to_i
    end
  end
end
