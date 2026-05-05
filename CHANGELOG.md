# Changelog

All notable changes to Harnas — both the specification and the
reference implementation — are recorded here.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and Harnas adheres to [Semantic Versioning](https://semver.org/) on
the specification as a whole.

## [Unreleased]

### v0.9.1

#### Added

- Manifest tool entries may now declare opaque `config`; the Ruby
  loader stores it in the Session manifest snapshot and makes it
  available to handlers as `config:`.
- Conformance now passes 28/28 fixtures, including
  `with-tool-config-roundtrip`.

### Added

- Added manifest-declared hook installation, `on_error: "fail_turn"`
  hook policy support, and terminal `:runtime_error` Log events for
  harness-internal failures.
- Added `Harnas::Observation::CostTracker` for cumulative token usage
  tracking.
- Strategies now emit Observation-only `:strategy_started` and
  `:strategy_completed` events with `noop`, `mutated`, `refused`, or
  `error` effects.
- Conformance now passes 27/27 fixtures, including manifest hooks,
  fail-turn runtime errors, and strategy-event sidecars.

### Fixed

- Clarified `StaleReadGuard` refusal messages so LLM consumers know when
  to call `read_file` before retrying a write/edit.

### Changed

- Rebuilt the web monitor surface around Tailwind-loaded HTML,
  extracted static CSS/ES module assets, and added strategy uninstall,
  session-library quick load, keyboard shortcuts, save/load toasts, and
  long-message expanders.
- Redesigned the web monitor configuration tab with presets,
  context-aware strategy forms, grouped tool controls, prompt helpers,
  active strategy cards, and provider/model controls.

## [0.8.0] — 2026-05-03

### Reference implementation (Ruby)

#### Changed

- Streaming transport events now emit on Observation as `:stream_event`
  and no longer append to the durable Log. Consolidated
  `:assistant_message` / `:tool_use` Events still append as before.
- `harnas chat` and the web monitor now render streaming from
  Observation rather than reading deltas back out of the Log.
- Conformance now passes 24/24 fixtures, including the
  `with-delta-logger-sidecar` fixture.

#### Added

- Added `Harnas::Observation::DeltaLogger` for opt-in sidecar JSONL
  persistence of streaming transport events.

#### Fixed

- OpenAI live streaming requests include
  `stream_options: { include_usage: true }`, preserving non-zero usage
  in the consolidated assistant message.

## [0.7.0] — 2026-05-02

### Reference implementation (Ruby)

#### Added

- `:assistant_message` now accepts an optional `reasoning` block list.
- Anthropic, OpenAI, and Gemini ingestors capture provider reasoning
  content into `payload.reasoning` when present.
- The Anthropic projection round-trips captured reasoning as thinking
  content blocks, including signatures, for follow-up turns.
- Conformance now passes 23/23 fixtures, including reasoning capture
  for Anthropic, OpenAI, and Kimi-shaped OpenAI-compatible responses.

## [0.6.0] — 2026-05-02

### Reference implementation (Ruby)

#### Changed

- No Ruby code changes. This release keeps the reference implementation
  aligned with the spec and sibling implementation tags while
  harnas-python reaches the same public feature surface.

## [0.5.0] — 2026-05-02

### Reference implementation (Ruby)

#### Added

- Added `harnas inspect <session.jsonl>` for operator-friendly
  inspection of persisted Sessions, with a compact timeline by default
  and `--json` for machine-readable output.
- Added `harnas fork`, `harnas diff`, and `harnas project` for
  persisted-Session operator workflows: fork a Log prefix, pinpoint
  structural divergence, and render a provider request from a saved
  Log slice without making a provider call.

## [0.4.0] — 2026-04-29

### Reference implementation (Ruby)

#### Changed

- The conformance runner now supports scripted provider errors and
  canonical compact JSON tool-stub arguments, covering 20 fixtures.
- Added `bin/conformance_roundtrip.rb` for Session JSONL
  cross-language round-trip conformance. The Ruby implementation can
  now save phase-1 Sessions and load Sessions produced by Python or Go
  before continuing phase 2.
- Added property-style RSpec coverage for mutation idempotence,
  projection purity, dense seq assignment, fork prefixes, and
  compact/revert composition.
- Conformance inputs can now fork the active Session and verify fork
  prefix/metadata before continuing.
- Conformance inputs can now append explicit `:compact` and `:revert`
  Mutation Events for mutation-chain fixtures.
- Agent conformance now covers ToolOutputCap + MarkerTail strategy
  composition.
- Buffered conformance scripts can now assert the projected provider
  request before returning a response.
- Scripted streaming fixtures can now model mid-stream provider
  failures by appending `:assistant_turn_failed` before raising the
  provider error.
- Added a scheduled GitHub Actions workflow for weekly live-provider
  smoke tests against Anthropic, OpenAI, and Gemini.
- `Harnas::Agent#stream(text) { |delta| ... }` exposes the streaming
  AgentLoop path from the façade and yields delta Events as they are
  appended.
- `harnas chat` now uses the façade streaming path so assistant text
  deltas can be printed as they arrive.
- `Harnas::Session#fork(at_seq:)` creates a new Session with a
  verbatim Log prefix and `forked_from` / `forked_at_seq` metadata.
- `Harnas::Agent#from_session(session)` creates a façade over a forked
  Session while reusing the existing agent wiring.
- `Harnas::Hooks` and `Harnas::Observation` are now instantiable
  Session-scoped buses. Each `Harnas::Session` owns `#hooks` and
  `#observation`, and `AgentLoop` invokes hooks through the active
  Session instead of the process-global registry.
- Manifest strategy installation now installs onto the Loaded
  Session. `session.install(StrategyClass, **config)` is the
  preferred strategy-install surface.
- The old `Harnas::Hooks.*` and `Harnas::Observation.*` module-style
  calls remain as backward-compatible wrappers around a process-global
  default instance for v0.3.

## [0.2.0] — 2026-04-28

### Reference implementation (Ruby)

#### Changed

- `Harnas::Manifest.load` now resolves provider API keys from the
  environment by default (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`,
  `GEMINI_API_KEY`), while explicit `api_keys:` values still
  override the environment.
- Public examples now run from the `harnas-ruby` repository root and
  rely on manifest-level API key resolution instead of manually
  passing keys through each example.
- RSpec conformance fixture paths now use the same `HARNAS_SPEC` /
  sibling checkout / legacy monorepo resolution order as the
  conformance CLI.
- `bin/harnas` now provides manifest-driven `chat` and `run`
  commands. The old `bin/chat.rb` entry point delegates to
  `bin/harnas chat`.
- `erb` was updated to 6.0.4.
- Agent-level conformance now includes streaming fixtures; the Ruby
  runner replays `provider-script-stream.json` through the AgentLoop
  streaming path.

## [0.1.0] — 2026-04-28

First substantively releasable version. The specification and the
Ruby reference implementation have been live-verified end-to-end
against three providers (Anthropic, OpenAI, Gemini) on a real
multi-turn tool-using agent workload.

### Specification

#### Added — normative

- §01 R1–R5: Append-only Log + Projections + Mutations as the
  substrate. The Log is sovereign; provider request bodies are
  pure functions of the Log.
- §01 R6–R8: **Annotative Events** category and the canonical
  `:annotation` Event type. Carries `{kind, data}` with dotted
  namespacing; projections MUST NOT include them in provider
  request bodies; compaction MAY shadow them.
- §01 R9–R11: **Provider error events**. The canonical
  `:provider_error` Event captures one failed `Provider.call`
  with `{provider, status, error_class, message, attempt,
  terminal}`. Non-terminal entries record retries; the terminal
  entry indicates the failure was final and the Session ends with
  reason `:provider_failed`.
- §01 explicit Scope and Out-of-Scope sections, including
  policy-level permissions, task-level evaluation, multi-agent
  orchestration, runtime environment integration, and cross-
  implementation telemetry export — all explicitly out of scope.
- §01 Adjacent specifications: explicit MCP positioning. Harnas
  composes with MCP, does not replace it.
- §18 (Agent Manifest) gained the optional top-level `system`
  field — a system prompt that projects into provider-specific
  slots (Anthropic top-level `system`, OpenAI `role: "system"`
  message, Gemini `systemInstruction.parts[]`).
- Sections 04 (Tools), 05 (Compaction), 06 (Benchmarks),
  07 (Permission), 13 (Observation), 14 (Hooks),
  15 (Streaming), 16 (Actions), 17 (Composition Rules),
  18 (Agent Manifest) all stable for 0.1.

#### Conformance

- Five canonical fixtures shipped under `spec/conformance/agents/`:
  `minimal-chat`, `with-marker-tail-compaction`, `with-tool-call`
  (Anthropic), `with-tool-call-openai`, `with-tool-call-gemini`.
  Any conformant implementation MUST reproduce these byte-for-byte.

### Reference implementation (Ruby)

#### Added

- `Harnas::Agent` façade — `Agent.from_manifest(path).chat(text)`.
  Wraps `Manifest.load` + `AgentLoop` for one-call ergonomics.
  Includes `use_provider` for test/demo overrides and `shutdown`
  for clean strategy uninstall.
- `Harnas::Log#save` / `Harnas::Log.load` — JSONL round-trip
  preserving seq, id, type, and payload (including re-symbolizing
  Symbol-valued payload fields).
- `Harnas::Session#save` / `Harnas::Session.load` — wraps the Log
  in a self-describing JSONL with a session header.
- `Harnas::Tools::Builtin` — eight canonical tool implementations:
  `read_file`, `write_file`, `edit_file`, `list_dir`, `glob`,
  `grep`, `run_shell`, `fetch_url`. Pasteable manifest descriptors;
  unsandboxed by design (compose with permission strategies for
  safety).
- `Harnas::Tools::Middleware` — composable wrappers: `Timed`,
  `Logged`, `Retried` (stateless per-wrap helpers), and
  `RateLimiter` (stateful, shared budget across wraps).
- `Harnas::Tools::Middleware::StaleReadGuard` — Log-sourced
  read-before-edit guard. State lives in `:annotation` events,
  so `Session.save` / `Session.load` round-trips guard state for
  free.
- `Harnas::Strategies::Compaction::ToolOutputCap` — canonical
  compaction strategy targeting oversized `:tool_result` payloads
  (the largest context-cost driver in production harnesses).
- `Harnas::Providers::RetryPolicy` — configurable retry / abort
  decisions for transient HTTP statuses (default 408, 429, 500,
  502, 503, 504) and network-style error classes, with
  exponential backoff. `AgentLoop` integrates it; failures land
  as `:provider_error` events in the Log.
- Live providers: Anthropic, OpenAI, Gemini — buffered and
  streaming variants. Tool-registry parity across all three
  (canonical Log → three wire shapes).
- `Harnas::Tools::Builtin` example agents:
  `examples/01-hello-world`, `02-tool-calling`, `03-provider-switch`,
  `04-builtin-tools`, `05-codebase-qa` (live).

#### Wire-format quirks absorbed into the Log substrate

- **Anthropic** — provider-issued `toolu_xxx` ids round-trip directly.
- **OpenAI** — provider-issued `call_xxx` ids round-trip directly.
- **Gemini** — function-name-as-id is replaced with a deterministic
  per-ingestor `gemini.<name>.<counter>` id, while wire-side
  `functionResponse.name` is recovered from the matching
  `:tool_use` in the Log. Thinking-mode `thoughtSignature` is
  round-tripped via `:annotation` events with kind
  `gemini.thought_signature`.

#### Tooling

- `bin/conformance.rb` — runs every fixture under
  `spec/conformance/agents/` against the reference and diffs the
  resulting Log.
- `bin/web.rb` — Puma-backed real-time browser inspector with
  five tabs (chat, context, timeline, runtime, config).
- `bin/chat.rb` — interactive REPL CLI.

### Numbers

- 539 RSpec examples, all passing
- 5/5 conformance fixtures, all passing
- RuboCop clean across 135 files
- 28 devlog entries
- 30 spec sections in `spec/`

## What's next: 0.3

Carryovers and deferred decisions, captured for posterity:

- **Production deployment safety.** `Harnas::Hooks` and
  `Harnas::Observation` should become per-Session instances so
  concurrent agents in one process cannot inherit each other's
  strategies or subscribers.
- **MCP client.** Spec already positions MCP as composable; no
  reference implementation yet. Once landed, every existing MCP
  server becomes a Harnas tool source.
- **`:tool_output_truncate` mutation** for tool-chain-preserving
  truncation. `ToolOutputCap` collapses a tool pair into a
  user-role summary today; a future mutation type could preserve
  the tool-call structure while shrinking the result.
- **Composability mixin for Tool objects** (`Harnas::Tools::Composable`)
  for tools that want to register their own hook handlers at
  install time. Today middleware composition is pure Ruby
  wrapping, which covers most cases — the lifecycle mixin would
  be motivated by a concrete use case we haven't found yet.

[0.4.0]: https://github.com/Tedo-ai/harnas-ruby/releases/tag/v0.4.0
[0.2.0]: https://github.com/Tedo-ai/harnas-ruby/releases/tag/v0.2.0
[0.1.0]: https://github.com/Tedo-ai/harnas-ruby/releases/tag/v0.1.0
