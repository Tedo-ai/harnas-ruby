# harnas-ruby

Ruby reference implementation of [Harnas](https://github.com/Tedo-ai/harnas) —
a specification for LLM agent harnesses. Passes 20/20 conformance fixtures
byte-identically with the spec; live providers Anthropic + OpenAI + Gemini;
577 RSpec examples; rubocop clean.

**Version 0.5.0** (2026-05-02). Tracks Harnas spec 0.5.0.

## What's in here

```
lib/                         — the library, top-level Harnas:: namespace
spec/                        — RSpec tests (NB: spec/ is the rspec convention,
                               not the Harnas specification — that lives in
                               the Tedo-ai/harnas repo)
bin/                         — CLI entry points: chat, conformance, web, smoke
web/                         — single-file static UI for the live web inspector
config/defaults.yml          — per-provider model defaults
examples/                    — 5 runnable example agents
manifests/                   — example agent manifests (declarative JSON)
Gemfile / Gemfile.lock       — dependencies
CHANGELOG.md                 — release notes
LICENSE                      — MIT
```

## Run

```sh
bundle install
bundle exec rspec               # 577 examples
bundle exec rubocop             # clean
bundle exec bin/conformance.rb  # 20/20 fixtures
bundle exec bin/harnas run examples/01-hello-world/manifest.json --input "hello"
bundle exec bin/harnas chat examples/05-codebase-qa/manifest.json
bundle exec bin/harnas inspect ~/.harnas/runs/<session>.jsonl
bundle exec bin/harnas diff run-a.jsonl run-b.jsonl
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
- Eight built-in tools (read_file, write_file, edit_file, list_dir, glob,
  grep, run_shell, fetch_url) under `Harnas::Tools::Builtin`.
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
