# frozen_string_literal: true

require "harnas/config"

RSpec.describe Harnas::Config do
  before { described_class.reset! }

  describe ".defaults" do
    it "loads the YAML file and returns a hash with symbol keys" do
      expect(described_class.defaults).to be_a(Hash)
      expect(described_class.defaults.keys).to include(:anthropic, :openai)
    end
  end

  describe ".for_provider" do
    it "returns the config hash for a known provider" do
      config = described_class.for_provider(:anthropic)
      expect(config).to include(:model)
    end

    it "accepts string provider names" do
      expect(described_class.for_provider("openai")).to include(:model)
    end

    it "raises ConfigError for an unknown provider" do
      expect { described_class.for_provider(:nonexistent) }
        .to raise_error(described_class::ConfigError, /no configuration/)
    end
  end

  describe ".default_model" do
    it "returns the model string for a known provider" do
      expect(described_class.default_model(:anthropic)).to be_a(String)
      expect(described_class.default_model(:anthropic)).not_to be_empty
    end
  end
end
