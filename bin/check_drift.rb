# frozen_string_literal: true

# Checks current README/status claims against gem metadata and the checked-out spec.

ROOT = File.expand_path("..", __dir__)

def fail!(message)
  warn "drift check failed: #{message}"
  exit 1
end

def spec_root
  explicit = ENV["HARNAS_SPEC"]
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

gemspec = File.read(File.join(ROOT, "harnas-ruby.gemspec"))
gem_version = gemspec[/spec\.version\s*=\s*"([^"]+)"/, 1] || fail!("could not read gemspec version")
fields = version_fields(spec_root)
spec_version = fields.fetch("harnas_version") { fail!("spec VERSION has no harnas_version") }
fixtures_version = fields.fetch("fixtures_version") { fail!("spec VERSION has no fixtures_version") }
count = fixture_count(spec_root)
readme = File.read(File.join(ROOT, "README.md"))

fail!("gem version #{gem_version} does not match spec #{spec_version}") unless gem_version == spec_version
fail!("README missing Version #{gem_version}") unless readme.include?("**Version #{gem_version}**")
fail!("README missing spec #{spec_version}") unless readme.include?("Tracks Harnas spec #{spec_version}")
fail!("README missing #{count}/#{count} conformance claim") unless readme.include?("Passes #{count}/#{count} conformance fixtures")
fail!("README conformance command comment is stale") unless readme.include?("bundle exec bin/conformance.rb  # #{count}/#{count} fixtures")

%w[0.19.3 70/70 65/65].each do |stale|
  fail!("README contains stale #{stale}") if readme.include?(stale)
end

puts "drift ok: harnas-ruby #{gem_version}, fixtures v#{fixtures_version}, #{count} agent fixtures"
