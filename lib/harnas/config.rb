# frozen_string_literal: true

require "yaml"

module Harnas
  # Loads provider defaults from config/defaults.yml.
  #
  # This module is informative: it exists to support the reference
  # implementation's tooling (smoke scripts, examples). Conforming
  # implementations of Harnas MAY choose any configuration approach.
  module Config
    DEFAULTS_PATH = File.expand_path(
      "../../config/defaults.yml",
      __dir__
    )

    class ConfigError < StandardError; end

    def self.defaults
      @defaults ||= begin
        unless File.exist?(DEFAULTS_PATH)
          raise ConfigError, "defaults file not found at #{DEFAULTS_PATH}"
        end

        YAML.load_file(DEFAULTS_PATH, symbolize_names: true)
      end
    end

    def self.for_provider(provider)
      key = provider.to_sym
      config = defaults[key]
      unless config
        raise ConfigError,
              "no configuration for provider: #{provider.inspect} " \
              "(available: #{defaults.keys.join(", ")})"
      end
      config
    end

    def self.default_model(provider)
      for_provider(provider).fetch(:model) do
        raise ConfigError, "no default model for provider: #{provider.inspect}"
      end
    end

    # Test helper: reset memoization so tests can stub the path.
    def self.reset!
      @defaults = nil
    end
  end
end
