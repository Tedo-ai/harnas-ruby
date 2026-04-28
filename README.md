# harnas-ruby

Ruby reference implementation of [Harnas](https://github.com/Tedo-ai/harnas) —
a specification for LLM agent harnesses. Passes 7/7 conformance fixtures
byte-identically with the spec; live providers Anthropic + OpenAI + Gemini;
550 RSpec examples; rubocop clean.

**Version 0.1.0** (2026-04-28). Tracks Harnas spec 0.1.0.

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
CHANGELOG.md                 — 0.1.0 release notes
LICENSE                      — MIT
```

## Run

```sh
bundle install
bundle exec rspec               # 550 examples
bundle exec rubocop             # clean
bundle exec bin/conformance.rb  # 7/7 fixtures
bundle exec bin/harnas run examples/01-hello-world/manifest.json --input "hello"
bundle exec bin/harnas chat examples/05-codebase-qa/manifest.json
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

## What's in 0.1.0

The full feature set landed for v0.1.0 is enumerated in [`CHANGELOG.md`](CHANGELOG.md).
Highlights:

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
