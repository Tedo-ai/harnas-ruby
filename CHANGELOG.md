# Changelog

All notable changes to Harnas — both the specification and the
reference implementation — are recorded here.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and Harnas adheres to [Semantic Versioning](https://semver.org/) on
the specification as a whole.

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

## What's next: 0.2

Carryovers and deferred decisions, captured for posterity:

- **Streaming conformance fixtures.** Streaming delta events exist
  but are not under fixture coverage. The retry-policy refactor
  in `AgentLoop` touches both buffered and streaming paths;
  streaming has zero live testing.
- **Second implementation.** A Python (or Go, or TS) port that
  passes the five fixtures is the largest remaining credibility
  move. The spec is now substantive enough that a port is real
  engineering, not a stub.
- **MCP client.** Spec already positions MCP as composable; no
  reference implementation yet. Once landed, every existing MCP
  server becomes a Harnas tool source.
- **Real CLI.** `bin/chat.rb` exists but is Anthropic-only and
  echo-tool-hardcoded. A `harnas chat <manifest>` and
  `harnas run <manifest> --input ...` would replace
  `bundle exec ruby examples/...` ergonomics.
- **Env-var API key resolution.** `api_keys:` is still passed
  explicitly everywhere; a default of `ENV["ANTHROPIC_API_KEY"]`
  etc. would make demos and deployment cleaner.
- **`:tool_output_truncate` mutation** for tool-chain-preserving
  truncation. `ToolOutputCap` collapses a tool pair into a
  user-role summary today; a future mutation type could preserve
  the tool-call structure while shrinking the result.
- **Composability mixin for Tool objects** (`Harnas::Tools::Composable`)
  for tools that want to register their own hook handlers at
  install time. Today middleware composition is pure Ruby
  wrapping, which covers most cases — the lifecycle mixin would
  be motivated by a concrete use case we haven't found yet.

[0.1.0]: https://github.com/Tedo-ai/harnas/releases/tag/v0.1.0
