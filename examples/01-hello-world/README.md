# 01 · hello-world

The smallest possible Harnas agent. Demonstrates:

- Loading a manifest (`manifest.json`) via `Harnas::Agent.from_manifest`
- Appending a user message and driving one turn via `#chat`
- Inspecting the Log (every interaction is a typed Event)

Uses the mock provider — no API key required.

## Run

From the repository root:

```sh
bundle install                              # one-time
bundle exec ruby examples/01-hello-world/run.rb
```

## Expected output

```
agent: hello-world
model: mock
---
user:      hello, are you there?
assistant: ok
stop:      end_turn
---
log has 2 events:
  seq 0 · user_message
  seq 1 · assistant_message
```

The mock provider always returns `"ok"`. Swap the manifest's
`provider.kind` to `"anthropic"`, `"openai"`, or `"gemini"` and set the
matching provider API key in the environment to run against a live model.
