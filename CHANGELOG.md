# Changelog

All notable changes to Harnas — both the specification and the
reference implementation — are recorded here.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and Harnas adheres to [Semantic Versioning](https://semver.org/) on
the specification as a whole.

## [Unreleased]

### Changed

- Added conformance replay support for malformed streaming provider
  frames. Validated against the expanded fixture set.
- Added a README drift check that compares public version and fixture-count
  claims with gem metadata and the checked-out spec.
- Added conformance aliases for the MarkerTail, hook, and fork canary
  fixtures. Validated against the expanded 75-fixture spec set.

## [0.19.4] — 2026-06-03

### Changed

- Lockstep spec patch release. Validated against fixtures version
  `0.19.4`: 70/70.
- Enforced §19's dense Event `seq` invariant when loading Session
  JSONL, failing loudly on duplicate, gapped, or reordered rows.
- Confirmed file-backed loading already fails loudly on torn final
  JSONL rows, satisfying the scoped S8 no-silent-corruption law.
- Bumped gem metadata and MCP client version to 0.19.4.

## [0.19.3] — 2026-06-01

### Changed

- Lockstep spec patch release. Validated against fixtures version
  `0.19.3`: 70/70.
- Conformance runner now honors `isolation.json` repeat checks so a
  fixture can assert that multiple Sessions run in one process without
  leaking mutable state.
- Scoped the built-in `bash_session` registry to each built-in handler
  bundle instead of one process-global registry.
- Bumped gem metadata and MCP client version to 0.19.3.

## [0.19.2] — 2026-06-01

### Changed

- Lockstep spec patch release. Validated against fixtures version
  `0.19.2`: 69/69.
- Confirmed projections preserve assistant text alongside co-occurring
  tool calls for Anthropic, OpenAI, and Gemini.
- Bumped gem metadata and MCP client version to 0.19.2.

## [0.19.1] — 2026-05-31

### Changed

- Lockstep spec patch release. Validated against fixtures version
  `0.19.1`: 66/66.
- Confirmed Anthropic projections preserve assistant text alongside
  co-occurring reasoning blocks on later turns.
- Bumped gem metadata and MCP client version to 0.19.1.

## [0.19.0] — 2026-05-24

### Added

- Added UTC ISO 8601 timestamps to Log events and preserved timestamps
  across Session save/load and fork.
- Added canonical assistant usage metadata with total/cache/reasoning
  token fields, raw provider usage, and provenance.
- Added provider/model identity on assistant provider-response events.
- Added optional `tool_result.payload.approval` metadata with the v0.19
  approval decision shape.

### Changed

- Lockstep spec release. Validated against fixtures version `0.19.0`:
  65/65.
- Bumped gem metadata and MCP client version to 0.19.0.

## [0.18.2] — 2026-05-22

### Added

- Added `shell_type` resolution for `harnas.builtin.bash_session` tool
  config and validated against fixtures version `0.18.2`: 62/62.
- Updated the bundled manifest schema with the `shell_type` config
  field.

### Changed

- Audited `bash_session` process handling for Windows portability and
  guarded negative-PID process-group signaling behind platform checks.
- Bumped gem metadata and MCP client version to 0.18.2.
- Lockstep patch release driven by AgentStaple's Windows preview
  packaging work.

## [0.18.1] — 2026-05-22

### Added

- Added event-id preservation checking to Session save/load conformance.
- Added spawn-agent reciprocity conformance: `spawn_agent` now creates a
  child Session with reciprocal delegation metadata and an initial task
  `user_message`.

### Changed

- Lockstep patch release driven by foss/harnas spec audit findings.
- Validated against fixtures version `0.18.1`: 61/61.
- Bumped gem metadata to 0.18.1.
- Audited capability manifest hashing against Go and Python; the v0.18.1
  sample manifest hashes identically across all three implementations.

## [0.18.0] — 2026-05-21

### Added

- Lockstep spec release. Validated against fixtures version `0.18.0`.
- Added subagent delegation event support, Session header delegation
  metadata, capability manifest helpers, and cross-session projection
  helpers.
- Added support for projection conformance fixtures via
  `expected-projections.jsonl`.
- Added optional `harnas.builtin.spawn_agent`, which records an
  `agent_spawn` receipt and returns generated child identifiers.
- Conformance now passes 59/59 fixtures, including the five subagent
  delegation fixtures.
- Bumped gem metadata to 0.18.0.

## [0.17.0] — 2026-05-21

### Added

- Added multimodal content block support for text, image, and PDF
  document message content.
- Added AttachmentStore helpers: filesystem, memory, and inline stores.
- Updated Anthropic, OpenAI, Gemini, and Ollama projections for
  multimodal content and provider capability mismatch fallback.
- Added CLI `--input-file` support for image and PDF attachments.
- Updated `Harnas::Transcript.project` to render non-text content
  placeholders.

### Changed

- Lockstep spec release. Validated against fixtures version `0.17.0`.
- Conformance now passes 54/54 fixtures, including the eight
  multimodal content fixtures.
- Bumped gem metadata to 0.17.0.

## [0.16.0] — 2026-05-21

### Added

- Added `credential/proxy`, a `:pre_tool_use` strategy that injects
  credential-backed headers into supported tool arguments while keeping
  credential values out of the Log and Observation stream.
- `fetch_url` now accepts optional request headers so credential/proxy can
  authorize HTTP calls without exposing secrets to the model.

### Changed

- Lockstep spec release. Validated against fixtures version `0.16.0`.
- Conformance now passes 46/46 fixtures, including
  `with-credential-proxy-injection`.

## [0.14.1] — 2026-05-21

### Added

- Conformance runner now supports `--fixtures-from` and reports the
  fixtures version from the spec repo `VERSION` file.
- Added packed-gem conformance CI: build the gem, install it outside
  the source tree, and run conformance against the installed artifact.

### Changed

- Validated against fixtures version `0.14.1`.

## [0.14.0] — 2026-05-21

### Added

- Added `sandbox/network`, a tool-boundary network strategy with exact host
  allow/deny enforcement for `fetch_url`.
- Extended `harnas.builtin.bash_session` so `run` accepts an optional
  per-command `env` object whose variables do not persist in the shell
  session.

### Changed

- Updated `harnas.builtin.read_file` to accept `offset` and `limit`, return
  `cat -n` style line-numbered output, and reject binary files.
- Conformance now passes 45/45 fixtures.

## [0.13.2] — 2026-05-20

### Added

- Added `args_key_style` for tool dispatch. Runtime callers can set
  `args_key_style: :string` globally, or a tool descriptor can set
  `"args_key_style": "string"` to receive JSON-native string keys.

### Fixed

- Added a clear manifest error when a `Harnas::Tools::Tool` instance is
  accidentally passed in `tools[]` instead of a Hash descriptor, with guidance
  to pass callables through `tool_handlers:`.

## [0.13.1] — 2026-05-19

### Fixed

- Bundled `agent-manifest.schema.json` inside the gem and made the bundled
  copy the primary schema resolution path, fixing standalone gem installs
  outside the Tedo monorepo.

## [0.13.0] — 2026-05-18

### Fixed

- Removed web-inspector-only dependencies (`rack`, `rackup`, `puma`, and
  `faye-websocket`) from the core gemspec so `require "harnas"` can embed
  cleanly in Rails applications with their own web stack. `bin/web.rb` now
  raises a clear LoadError explaining which gems to add when the web
  inspector is used.
- Aligned the gemspec package name with the repository/install name:
  `harnas-ruby`. The runtime require path remains `require "harnas"`.

### Added

- Added `guard/health`, a pre-provider health-check strategy.
- Extended `guard/repetition` to detect repeated approval rejections.
- Added Ollama buffered and streaming providers using Ollama's
  OpenAI-compatible `/v1/chat/completions` endpoint, plus
  `bin/smoke_ollama.rb`.

## [0.12.0] — 2026-05-18

### Added

- Added `sandbox/write`, `guard/repetition`, `guard/timeout`, and
  `guard/cost_budget` strategies.
- Added `--output-format ndjson` for `bin/harnas run`.
- Applied the shared CLI exit-code taxonomy and partial stdout flush on
  exit-1 agent failures.
- Conformance now passes 39/39 fixtures.

## [0.11.0] — 2026-05-17

### Added

- Promoted `harnas.builtin.bash_session` to the conformable surface. It
  preserves shell working directory and environment changes across named
  sessions and returns both cumulative transcript fields and
  command-local stdout/stderr.
- Added `Harnas::MCP` with HTTP and stdio transport clients. MCP tool
  descriptors translate to namespaced Harnas tools automatically, with
  dynamic handlers that call back into the MCP server.
- Added MCP content flattening for text, image, resource, and unknown
  content types, plus degraded startup behavior where discovery
  failures log a warning and return an empty tool list.
- Added adopter helper surfaces: `Harnas::Runtime`,
  `Harnas::Transcript.project`, and `Harnas::Tools::Snapshot`.
- Conformance now passes 34/34 fixtures, including the four
  `bash_session` fixtures.

## [0.10.0] — 2026-05-10

### Added

- Added `Harnas::Skills.build_index`, which scans a skills directory
  and emits the canonical `## Skills` system-prompt section.
- Added the `harnas.builtin.load_skill` built-in tool with
  config-driven `skills_dir`, frontmatter stripping, skill-name
  validation, and empty-body support.
- Conformance now passes 30/30 fixtures, including `with-skills` and
  `with-skills-invalid-name`.

## [0.9.3] — 2026-05-10

### Informative

- Tracks the v0.9.3 spec, which adds non-normative ecosystem
  conventions for skills and MCP mappings. No Ruby runtime behavior
  changes; the `load_skill` built-in and skills-index helper are
  planned for v0.10.

## [0.9.2] — 2026-05-08

### Conformance

- Tracks the v0.9.2 spec, which hardens `with-tool-call-openai` to
  assert on the second projected request via `expect_request`. The
  Ruby `Projections::OpenAI` already conformed to the clarified
  contract (folds `:tool_use` into the preceding assistant message's
  `tool_calls[]`, emits `:tool_result` as `role: "tool"`, normalizes
  `content` to `null` when `tool_calls[]` is present); this release
  bumps the version in lockstep so "running spec X means impl X"
  stays simple. No code changes.

## [0.9.1] — 2026-05-05

### Trust polish

- Updated README version, fixture-count, and RSpec-count language to
  match the verified v0.9.1 surface.
- Added a buildable Ruby gemspec so the library has a concrete package
  artifact even before RubyGems publishing.
- Added `lib/harnas.rb` as the package-level require entry point.
- Added normal push/PR CI for RSpec, RuboCop, and conformance.

### v0.9.1

#### Added

- Manifest tool entries may now declare opaque `config`; the Ruby
  loader stores it in the Session manifest snapshot and makes it
  available to handlers as `config:`.
- Conformance now passes 28/28 fixtures, including
  `with-tool-config-roundtrip`.

## [0.9.0] — 2026-05-05

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

[0.19.4]: https://github.com/Tedo-ai/harnas-ruby/releases/tag/v0.19.4
[0.19.3]: https://github.com/Tedo-ai/harnas-ruby/releases/tag/v0.19.3
[0.19.2]: https://github.com/Tedo-ai/harnas-ruby/releases/tag/v0.19.2
[0.19.1]: https://github.com/Tedo-ai/harnas-ruby/releases/tag/v0.19.1
[0.19.0]: https://github.com/Tedo-ai/harnas-ruby/releases/tag/v0.19.0
[0.18.2]: https://github.com/Tedo-ai/harnas-ruby/releases/tag/v0.18.2
[0.18.1]: https://github.com/Tedo-ai/harnas-ruby/releases/tag/v0.18.1
[0.18.0]: https://github.com/Tedo-ai/harnas-ruby/releases/tag/v0.18.0
[0.17.0]: https://github.com/Tedo-ai/harnas-ruby/releases/tag/v0.17.0
[0.16.0]: https://github.com/Tedo-ai/harnas-ruby/releases/tag/v0.16.0
[0.14.1]: https://github.com/Tedo-ai/harnas-ruby/releases/tag/v0.14.1
[0.14.0]: https://github.com/Tedo-ai/harnas-ruby/releases/tag/v0.14.0
[0.13.2]: https://github.com/Tedo-ai/harnas-ruby/releases/tag/v0.13.2
[0.13.1]: https://github.com/Tedo-ai/harnas-ruby/releases/tag/v0.13.1
[0.13.0]: https://github.com/Tedo-ai/harnas-ruby/releases/tag/v0.13.0
[0.12.0]: https://github.com/Tedo-ai/harnas-ruby/releases/tag/v0.12.0
[0.11.0]: https://github.com/Tedo-ai/harnas-ruby/releases/tag/v0.11.0
[0.10.0]: https://github.com/Tedo-ai/harnas-ruby/releases/tag/v0.10.0
[0.9.3]: https://github.com/Tedo-ai/harnas-ruby/releases/tag/v0.9.3
[0.9.2]: https://github.com/Tedo-ai/harnas-ruby/releases/tag/v0.9.2
[0.9.1]: https://github.com/Tedo-ai/harnas-ruby/releases/tag/v0.9.1
[0.9.0]: https://github.com/Tedo-ai/harnas-ruby/releases/tag/v0.9.0
[0.8.0]: https://github.com/Tedo-ai/harnas-ruby/releases/tag/v0.8.0
[0.7.0]: https://github.com/Tedo-ai/harnas-ruby/releases/tag/v0.7.0
[0.6.0]: https://github.com/Tedo-ai/harnas-ruby/releases/tag/v0.6.0
[0.5.0]: https://github.com/Tedo-ai/harnas-ruby/releases/tag/v0.5.0
[0.4.0]: https://github.com/Tedo-ai/harnas-ruby/releases/tag/v0.4.0
[0.2.0]: https://github.com/Tedo-ai/harnas-ruby/releases/tag/v0.2.0
[0.1.0]: https://github.com/Tedo-ai/harnas-ruby/releases/tag/v0.1.0
