# 05 · codebase-qa (live)

First LIVE example. Runs a real Harnas agent against a real
provider endpoint, using everything we've built:

- A system prompt (from the manifest)
- The full built-in tool library: `read_file`, `list_dir`, `glob`,
  `grep`, `edit_file`
- `StaleReadGuard` wrapping every file-touching tool (Log-sourced —
  state survives `Session.save`/`Session.load`)
- `Compaction::MarkerTail` installed as a strategy
- Provider-switchable via `--provider anthropic|openai|gemini`

**Requires an API key.** Set `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`,
or `GEMINI_API_KEY` in the environment or `.env`. The manifest loader
resolves the matching key automatically for the selected provider.

**Auto-saves every run** to
`examples/05-codebase-qa/runs/<provider>-<YYYYMMDD-HHMMSS>.jsonl`
so the Log can be inspected or re-loaded later. Override with
`--save PATH` or skip with `--no-save`. The `runs/` directory is
gitignored.

## Run

```sh
bundle exec ruby examples/05-codebase-qa/run.rb \
  "what compaction strategies does this repo ship?"
```

Other providers:

```sh
bundle exec ruby examples/05-codebase-qa/run.rb --provider openai \
  "summarize the canonical event types in spec/01-overview.md"

bundle exec ruby examples/05-codebase-qa/run.rb --provider gemini \
  "find all :tool_result emissions in lib"
```

## Good dogfood prompts (copy-paste)

The more tool calls a prompt forces, the more of the stack it
exercises.

```
"what compaction strategies does this repo ship?"
"summarize spec/01-overview.md in three sentences"
"find every place where :annotation is emitted"
"list the built-in tools and their descriptions"
"how many canonical event types are there in the reference impl?"
```

## What gets exercised

End-to-end, in a single run:

- `Harnas::Agent.from_manifest` — manifest load + strategy install
- Per-provider projection (including the new `:system` field)
- Live streaming wire contact with the provider
- Tool registry dispatch through `Tools::Runner`
- `Harnas::Tools::Builtin` tool handlers
- `StaleReadGuard` Log annotations on every read/edit/write
- `Compaction::MarkerTail` firing once the message count grows
- The full `:user_message → :assistant_message → :tool_use →
  :tool_result → :assistant_message` Log shape, possibly looping
  through multiple tool-use rounds

## What to watch for

Things that would indicate real gaps (not bugs in the prompt):

- **Provider errors crash the loop.** A 429 / 500 / timeout should
  become a recoverable event, not an exception out of `AgentLoop.run`.
  Today it probably isn't — this is the biggest open P1.
- **Tool result truncation.** If a `grep` or `read_file` returns more
  bytes than the provider will accept, the turn fails rather than
  truncating gracefully. `ToolOutputCap` addresses the long-term
  case but not a single oversized turn before it triggers.
- **Tool-use id correlation across providers.** Anthropic / OpenAI /
  Gemini each have different id conventions; if the Gemini path
  breaks on same-function-twice-in-a-turn, that's a known
  structural limitation, not a bug.
- **Max turns hit without a stop.** The AgentLoop caps at 10 turns
  by default. If the agent is still calling tools at turn 10,
  the session ends with `reason: :max_turns_reached`.
