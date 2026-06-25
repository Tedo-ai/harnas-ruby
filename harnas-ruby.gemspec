# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "harnas-ruby"
  spec.version = "0.20.1"
  spec.authors = ["René van Pelt"]
  spec.email = ["contact@renevanpe.lt"]

  spec.summary = "Ruby reference implementation of Harnas"
  spec.description = "Ruby reference implementation of the Harnas agent substrate."
  spec.homepage = "https://github.com/Tedo-ai/harnas-ruby"
  spec.license = "MIT"
  # The runtime uses Ruby's Data class, which is available in Ruby 3.2+.
  spec.required_ruby_version = ">= 3.2" # rubocop:disable Gemspec/RequiredRubyVersion

  spec.metadata = {
    "source_code_uri" => "https://github.com/Tedo-ai/harnas-ruby",
    "changelog_uri" => "https://github.com/Tedo-ai/harnas-ruby/blob/main/CHANGELOG.md",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir.chdir(__dir__) do
    Dir["lib/**/*", "bin/*", "config/**/*", "web/**/*", "*.md", "LICENSE"]
      .reject { |path| File.directory?(path) }
  end
  spec.bindir = "bin"
  spec.executables = ["harnas"]
  spec.require_paths = ["lib"]

  spec.add_dependency "base64", "~> 0.3"
  spec.add_dependency "dotenv", "~> 3.1"
  spec.add_dependency "httpx", "~> 1.7"
  spec.add_dependency "json_schemer", "~> 2.5"

  # Web inspector only: add rack ~> 3.2, rackup ~> 2.3,
  # puma ~> 8.0, and faye-websocket ~> 0.12 to your Gemfile if
  # using bin/web.rb.
end
