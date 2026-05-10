# frozen_string_literal: true

Gem::Specification.new do |spec| # rubocop:disable Metrics/BlockLength
  spec.name = "harnas"
  spec.version = "0.10.0"
  spec.authors = ["René van Pelt"]
  spec.email = ["contact@renevanpe.lt"]

  spec.summary = "Ruby reference implementation of Harnas"
  spec.description = "Ruby reference implementation of Harnas, " \
                     "a specification for LLM agent harnesses."
  spec.homepage = "https://github.com/Tedo-ai/harnas-ruby"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.4"

  spec.metadata = {
    "source_code_uri" => "https://github.com/Tedo-ai/harnas-ruby",
    "changelog_uri" => "https://github.com/Tedo-ai/harnas-ruby/blob/main/CHANGELOG.md",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir.chdir(__dir__) do
    Dir.glob("{bin,config,lib,web}/**/*", File::FNM_DOTMATCH)
       .reject { |path| File.directory?(path) }
  end
  spec.bindir = "bin"
  spec.executables = ["harnas"]
  spec.require_paths = ["lib"]

  spec.add_dependency "dotenv", "~> 3.1"
  spec.add_dependency "faye-websocket", "~> 0.12"
  spec.add_dependency "httpx", "~> 1.7"
  spec.add_dependency "json_schemer", "~> 2.5"
  spec.add_dependency "puma", "~> 8.0"
  spec.add_dependency "rack", "~> 3.2"
  spec.add_dependency "rackup", "~> 2.3"
end
