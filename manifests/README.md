# Example Agent Manifests

Sample manifests demonstrating the Agent Manifest format
(spec/18-agent-manifest.md, v0.1).

## Files

- **`minimal_agent.json`** — the smallest valid manifest. Mock
  provider (CannedProvider under the hood), no tools, no strategies.
  Useful as a starting point and for load-test fixtures.

- **`research_agent.json`** — a realistic research agent. Anthropic
  provider; web_search / web_fetch / write_file tools; stacked
  compaction + permission strategies. Tool handlers and the
  HumanApproval prompt are symbolic references (`acme.*`) that the
  consumer's code must resolve at load time.

## Loading

```ruby
require "harnas/manifest"

loaded = Harnas::Manifest.load(
  "examples/research_agent.json",
  api_keys: { anthropic: ENV.fetch("ANTHROPIC_API_KEY") },
  tool_handlers: {
    "acme.tools.websearch.search" => ->(args) { my_search(args[:q]) },
    "acme.tools.websearch.fetch"  => ->(args) { my_fetch(args[:url]) },
    "acme.tools.fs.write"         => ->(args) { File.write(args[:path], args[:content]) }
  },
  strategy_handlers: {
    "acme.approvals.cli_prompt" => ->(tool_use) {
      print "allow #{tool_use.payload[:name]}? [y/N] "
      $stdin.gets.chomp.downcase == "y"
    }
  }
)

loaded.install_strategies!

Harnas::AgentLoop.new(
  session:    loaded.session,
  projection: loaded.projection,
  provider:   loaded.provider,
  ingestor:   loaded.ingestor,
  runner:     loaded.runner
).run
```
