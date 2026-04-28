# 02 · tool-calling

A Harnas agent with one registered tool (`get_current_time`) and the
full tool-use round-trip. Demonstrates:

- Declaring a tool in the manifest
- Resolving the symbolic handler name to a Ruby callable at load time
- The two-turn loop: assistant requests the tool → harness dispatches
  it → `:tool_result` appended → assistant synthesizes a final reply
- The canonical Log shape for a tool-calling conversation

Uses the mock provider plus a `ScriptedProvider` override so the
example is deterministic — no API key required.

## Run

```sh
cd reference
bundle exec ruby ../examples/02-tool-calling/run.rb
```

## Expected output

```
agent: tool-calling
---
user:      what time is it?
assistant: The current time is now available in the Log.
stop:      end_turn
---
log (5 events):
  seq 0  user_message         what time is it?
  seq 1  assistant_message
  seq 2  tool_use             get_current_time({})
  seq 3  tool_result          2026-04-22T…
  seq 4  assistant_message    The current time is now available in the Log.
```

The five-event sequence is the canonical Harnas tool-call shape;
every conformant implementation in any language, against any
provider, produces the same sequence when given the same scripted
responses. The per-provider wire format differs (`tool_use` /
`tool_calls` / `functionCall`); the Log does not.
