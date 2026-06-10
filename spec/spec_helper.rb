# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

module HarnasSpecPaths
  def self.spec_root
    if ENV["HARNAS_SPEC"]
      ENV["HARNAS_SPEC"]
    elsif File.directory?(File.expand_path("../../harnas", __dir__))
      File.expand_path("../../harnas", __dir__)
    else
      File.expand_path("../../spec", __dir__)
    end
  end

  def self.conformance_agents
    File.join(spec_root, "conformance", "agents")
  end

  def self.conformance_fixture(*parts)
    File.join(spec_root, "conformance", "fixtures", *parts.map(&:to_s))
  end

  def self.conformance_oracle(*parts)
    File.join(spec_root, "conformance", "oracle-corpus", *parts.map(&:to_s))
  end

  def harnas_conformance_fixture(*parts)
    HarnasSpecPaths.conformance_fixture(*parts)
  end

  def harnas_conformance_oracle(*parts)
    HarnasSpecPaths.conformance_oracle(*parts)
  end
end

RSpec.configure do |config|
  config.include HarnasSpecPaths
end
