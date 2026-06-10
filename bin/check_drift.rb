# frozen_string_literal: true

# Checks current README/status claims against gem metadata and the checked-out spec.

require "digest"
require "json"

ROOT = File.expand_path("..", __dir__)

def fail!(message)
  warn "drift check failed: #{message}"
  exit 1
end

def spec_root
  explicit = ENV.fetch("HARNAS_SPEC", nil)
  return explicit if explicit && File.directory?(explicit)

  sibling = File.expand_path("../../harnas", __dir__)
  return sibling if File.directory?(File.join(sibling, "conformance", "agents"))

  fail!("set HARNAS_SPEC to a Harnas spec checkout")
end

def version_fields(root)
  File.readlines(File.join(root, "VERSION"), chomp: true).each_with_object({}) do |line, fields|
    next unless line.include?(":")

    key, value = line.split(":", 2)
    fields[key.strip] = value.strip
  end
end

def fixture_count(root)
  Dir.children(File.join(root, "conformance", "agents")).count do |name|
    File.directory?(File.join(root, "conformance", "agents", name)) &&
      File.exist?(File.join(root, "conformance", "agents", name, "manifest.json"))
  end
end

def fixture_hashes(root)
  agents = File.join(root, "conformance", "agents")
  Dir.children(agents).sort.each_with_object({}) do |name, hashes|
    path = File.join(agents, name)
    next unless File.directory?(path) && File.exist?(File.join(path, "manifest.json"))

    expected_log = File.join(path, "expected-log.jsonl")
    fail!("conformance/agents/#{name} has no expected-log.jsonl") unless File.exist?(expected_log)

    hashes[name] = Digest::SHA256.file(expected_log).hexdigest
  end
end

def expected_corpus_hashes(root, fixtures_version)
  manifest_path = File.join(root, "conformance", "corpus-manifest.json")
  fail!("spec conformance/corpus-manifest.json is missing") unless File.exist?(manifest_path)

  versions = JSON.parse(File.read(manifest_path))["versions"]
  fail!("spec corpus manifest has no versions object") unless versions.is_a?(Hash)

  entry = versions[fixtures_version]
  unless entry.is_a?(Hash)
    fail!("spec corpus manifest has no entry for fixtures_version #{fixtures_version}")
  end

  expected = entry["agents"]
  unless expected.is_a?(Hash)
    fail!("spec corpus manifest entry #{fixtures_version} has no agents object")
  end

  expected
end

def append_mismatch_part(parts, label, names)
  parts << "#{label}: #{names.join(", ")}" unless names.empty?
end

def corpus_mismatch_message(actual, expected)
  parts = []
  append_mismatch_part(
    parts,
    "new fixtures without version bump",
    (actual.keys - expected.keys).sort
  )
  append_mismatch_part(
    parts,
    "manifest contains removed fixtures",
    (expected.keys - actual.keys).sort
  )
  append_mismatch_part(
    parts,
    "expected-log hashes changed",
    (actual.keys & expected.keys).reject { |name| actual[name] == expected[name] }.sort
  )
  parts.empty? ? "spec corpus manifest does not match live fixtures" : parts.join("; ")
end

def require_corpus_manifest(root, fixtures_version)
  actual = fixture_hashes(root)
  expected = expected_corpus_hashes(root, fixtures_version)
  return if actual == expected

  fail!(corpus_mismatch_message(actual, expected))
end

gemspec = File.read(File.join(ROOT, "harnas-ruby.gemspec"))
gem_version = gemspec[/spec\.version\s*=\s*"([^"]+)"/, 1] || fail!("could not read gemspec version")
spec = spec_root
fields = version_fields(spec)
spec_version = fields.fetch("harnas_version") { fail!("spec VERSION has no harnas_version") }
fixtures_version = fields.fetch("fixtures_version") do
  fail!("spec VERSION has no fixtures_version")
end
require_corpus_manifest(spec, fixtures_version)
count = fixture_count(spec)
readme = File.read(File.join(ROOT, "README.md"))

if gem_version != spec_version
  fail!("gem version #{gem_version} does not match spec #{spec_version}")
end
fail!("README missing Version #{gem_version}") unless readme.include?("**Version #{gem_version}**")
unless readme.include?("Tracks Harnas spec #{spec_version}")
  fail!("README missing spec #{spec_version}")
end
unless readme.include?("Passes #{count}/#{count} conformance fixtures")
  fail!("README missing #{count}/#{count} conformance claim")
end
unless readme.include?("bundle exec bin/conformance.rb  # #{count}/#{count} fixtures")
  fail!("README conformance command comment is stale")
end

%w[0.19.3 70/70 65/65].each do |stale|
  fail!("README contains stale #{stale}") if readme.include?(stale)
end

puts "drift ok: harnas-ruby #{gem_version}, fixtures v#{fixtures_version}, #{count} agent fixtures"
