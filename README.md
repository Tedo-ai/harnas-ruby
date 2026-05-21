# harnas-ruby

Ruby reference implementation of [Harnas](https://github.com/Tedo-ai/harnas) —
a specification for LLM agent harnesses. Passes 59/59 conformance fixtures
against the spec; live providers Anthropic + OpenAI + Gemini + Ollama; 689 RSpec
examples; rubocop clean.

**Version 0.18.0** (2026-05-21). Tracks Harnas spec 0.18.0.

## What's in here

```
lib/                         — the library, top-level Harnas:: namespace
spec/                        — RSpec tests (NB: spec/ is the rspec convention,
                               not the Harnas specification — that lives in
                               the Tedo-ai/harnas repo)
bin/                         — CLI entry points: chat, conformance, web, smoke
web/                         — modular static UI for the live web inspector
config/defaults.yml          — per-provider model defaults
examples/                    — 5 runnable example agents
manifests/                   — example agent manifests (declarative JSON)
Gemfile / Gemfile.lock       — development dependencies
harnas-ruby.gemspec          — package metadata for building the gem
CHANGELOG.md                 — release notes
LICENSE                      — MIT
```

## Compatibility

**Ruby:** 3.2 and above.

The runtime uses Ruby's `Data` class, which is built into Ruby 3.2+.

**Ruby 3.4 note:** Ruby 3.4 removed several standard library files that were
previously bundled automatically. If you are on Ruby 3.4 and see `LoadError`
for any of the following, add them explicitly to your Gemfile:

```ruby
gem "mutex_m"
gem "bigdecimal"
gem "ostruct"
gem "drb"
gem "csv"
gem "base64"
gem "logger"
gem "benchmark"
```

This is a Ruby ecosystem issue, not a harnas issue, but the list above covers
what Rails 7.0 + common gems need.

**Rails:** harnas-ruby has no Rails dependency. It embeds into any Rails
version. The web inspector (`bin/web.rb`) requires `rack ~> 3.2`,
`rackup ~> 2.3`, `puma ~> 8.0`, and `faye-websocket ~> 0.12`, which conflict
with Rails 7.0's rack 2.x. If you are on Rails 7.0 and do not need the web
inspector, no action is required: the agent runtime works as-is. If you need
the web inspector on Rails 7.0, run it as a separate process.

## Run

```sh
bundle install
bundle exec rspec               # 689 examples
bundle exec rubocop             # clean
bundle exec bin/conformance.rb  # 59/59 fixtures
bundle exec bin/harnas run examples/01-hello-world/manifest.json --input "hello"
bundle exec bin/harnas chat examples/05-codebase-qa/manifest.json
bundle exec bin/harnas inspect ~/.harnas/runs/<session>.jsonl
bundle exec bin/harnas diff run-a.jsonl run-b.jsonl
```

`bin/conformance.rb` resolves fixtures from a sibling checkout of
[`Tedo-ai/harnas`](https://github.com/Tedo-ai/harnas), or from
`HARNAS_SPEC` when set. For a fresh clone, put the spec and Ruby repos
next to each other:

```
~/code/
├── harnas/       ← clone of Tedo-ai/harnas
└── harnas-ruby/  ← clone of Tedo-ai/harnas-ruby
```

`bin/harnas` is the manifest-driven CLI:

- `harnas run <manifest> --input "..."` sends one prompt, prints the
  final assistant response, saves the Session to
  `~/.harnas/runs/<timestamp>-<manifest_name>.jsonl`, and exits.
- `harnas chat <manifest>` starts a minimal REPL, preserving the Log
  across turns and saving the Session on exit.
- Both commands accept `--provider KIND` and `--model MODEL`; provider
  switches use the same model resolution as the examples:
  `--model` > `<PROVIDER>_MODEL` > `config/defaults.yml`.
- Manifest tools whose handler starts with `harnas.builtin.` are
  resolved automatically from `Harnas::Tools::Builtin.handlers`.
- `harnas inspect <session.jsonl>` loads a saved Session and prints a
  compact metadata summary, event counts, and timeline. Use `--json`
  for machine-readable output.
- `harnas fork <session.jsonl> --at-seq N --out <new.jsonl>` writes a
  forked Session whose Log preserves the original prefix through `N`.
- `harnas diff <a.jsonl> <b.jsonl>` pinpoints the first divergent
  Session header or Event seq between two persisted Sessions.
- `harnas project <session.jsonl> --manifest PATH [--from-seq N]
  [--to-seq M]` renders the provider request body that a manifest's
  projection would produce from a saved Log slice, without calling the
  provider.

`Harnas::Agent` also exposes a streaming façade:

```ruby
agent.stream("hello") do |delta|
  print delta.payload[:chunk] if delta.type == :assistant_text_delta
end
```

## Runtime Scope

Each `Harnas::Session` owns its own hook and observation buses:
`session.hooks` and `session.observation`. Strategies installed from a
manifest are scoped to that Session, so multiple agents can run in the
same process without inheriting each other's handlers or subscribers.

The legacy `Harnas::Hooks.*` and `Harnas::Observation.*` APIs remain
available as process-global compatibility wrappers for v0.3.

Sessions can be forked for rewind-and-retry flows:

```ruby
forked = agent.session.fork(at_seq: 12)
retry_agent = agent.from_session(forked)
retry_agent.chat("try a different approach")
```

## MCP adapters

`Harnas::MCP` connects an MCP server and translates its discovered tools
into ordinary Harnas tool descriptors. HTTP JSON-RPC and stdio
subprocess transports share the same interface; failures during
handshake or tool discovery degrade to an empty tool list so an optional
MCP server does not crash agent startup.

`tool_handlers:` is required whenever your manifest includes tools whose
handlers are not built-ins. Omitting it produces an unhelpful runtime
error.

```ruby
mcp = Harnas::MCP.connect(
  url: ENV.fetch("EDITORIAL_AI_MCP_URL"),
  server_name: "editorial-ai"
)

manifest = {
  "harnas_version" => "0.1",
  "name" => "editorial-pipeline",
  "provider" => { "kind" => "anthropic", "model" => "claude-sonnet-4-5" },
  "system" => editorial_brief,
  "tools" => mcp.tools,
  "strategies" => []
}

runtime = Harnas::Runtime.build(
  manifest:      manifest,          # tool descriptors (name, description, schema)
  tool_handlers: mcp.tool_handlers, # callables — required when using MCP tools
  args_key_style: :string,          # MCP arguments are JSON-native string keys
  metadata: { "story_uid" => uid }
)

result = runtime.agent.chat("Process story #{uid}. Run the full pipeline.")
```

For stdio servers, pass `command:` and optional `args:` instead of
`url:`. MCP tool names are exposed to the model as
`<server>.<tool>` (for example, `editorial-ai.fetch_story`) while the
adapter calls the original MCP tool name on the wire. Tool results are
flattened to a single string: text items join with blank lines, images
and resources become concise placeholders, and unknown content types
remain visible as typed placeholders.

### Tool argument key style

Tool handlers receive symbol-keyed argument hashes by default
(`{ model: "gpt-4", temperature: 0.7 }`). If you are integrating with MCP,
LangChain, or any framework that uses string keys, set
`args_key_style: :string` on `Runtime.build` or per tool in the manifest
descriptor.

## Live providers

Set the relevant API key in `.env` (gitignored) or the environment.
`Harnas::Manifest.load` and `Harnas::Agent.from_manifest` resolve the
matching key automatically unless `api_keys:` explicitly overrides it:

```
ANTHROPIC_API_KEY=sk-ant-...
OPENAI_API_KEY=sk-...
GEMINI_API_KEY=AIza...
```

Then a live agent against this very repo as a workspace:

```sh
bundle exec ruby examples/05-codebase-qa/run.rb \
  "what compaction strategies does this repo ship?"
```

Same prompt across providers:

```sh
bundle exec ruby examples/05-codebase-qa/run.rb --provider openai "..."
bundle exec ruby examples/05-codebase-qa/run.rb --provider gemini "..."
bundle exec ruby examples/05-codebase-qa/run.rb --provider ollama "..."
```

Each run auto-saves to `examples/05-codebase-qa/runs/<provider>-<timestamp>.jsonl`
(gitignored) so the Log can be inspected or reloaded.

## What's in 0.2.0

The full feature set landed for v0.2.0 is enumerated in [`CHANGELOG.md`](CHANGELOG.md).
Highlights:

- Manifest-driven CLI (`bin/harnas chat` and `bin/harnas run`).
- Manifest API key resolution from `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`,
  and `GEMINI_API_KEY`.
- Agent-level streaming conformance fixture replay; 7/7 fixtures.
- All three live providers (buffered + streaming) with full tool-registry
  parity. One canonical Log; three wire shapes.
- Ten built-in tools (read_file, write_file, edit_file, list_dir, glob,
  grep, run_shell, fetch_url, load_skill, bash_session)
  under `Harnas::Tools::Builtin`.
- Adopter helper APIs: `Harnas::Runtime` for create/resume/save assembly,
  `Harnas::Transcript.project` for UI-neutral Log views, and
  `Harnas::Tools::Snapshot` for dynamic tool metadata.
- Cross-session delegation projections:
  `Harnas::Projection.delegation_tree`,
  `Harnas::Projection.descendant_timeline`,
  `Harnas::Projection.open_children`, and
  `Harnas::Projection.descendant_usage`.
- Optional `harnas.builtin.spawn_agent` receipt built-in for products
  that want the common delegation tool shape.
- Four canonical compaction strategies (MarkerTail, TokenMarkerTail,
  SummaryTail, ToolOutputCap).
- Composable tool middleware (Timed, Logged, Retried, RateLimiter)
  plus a Log-sourced StaleReadGuard for read-before-edit safety.
- Agent façade (`Harnas::Agent.from_manifest(path).chat(text)`).
- Log + Session JSONL persistence (Session.save / Session.load).
- `:annotation` and `:provider_error` canonical events; `RetryPolicy`
  for transient-failure recovery in the AgentLoop.
- Web inspector at `bin/web.rb` with five tabs (chat, context, timeline,
  runtime, config).

## License

[MIT](LICENSE).
