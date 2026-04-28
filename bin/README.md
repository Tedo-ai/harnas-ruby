# Reference Implementation Scripts

These scripts are part of Harnas's **reference implementation**. They are
informative — not normative — and exist to demonstrate the specification
by making real calls to LLM providers.

## Smoke Tests

One script per supported provider, for verifying end-to-end connectivity:

- `smoke_anthropic.rb` — calls Anthropic's Messages API
- `smoke_openai.rb` — calls OpenAI's Chat Completions API
- `smoke_gemini.rb` — calls Google Gemini's generateContent API

### Setup

Set the relevant API keys in `reference/.env` (copy `.env.example` first):

    ANTHROPIC_API_KEY=sk-ant-...
    OPENAI_API_KEY=sk-...
    GEMINI_API_KEY=...

### Usage

From the repo root:

    just smoke           # call every provider live
    just mock-smoke      # replay recorded fixtures (offline, no keys)
    just record          # re-record fixtures from live APIs

Or invoke a single script from `reference/`:

    bundle exec bin/smoke_anthropic.rb hello in one word
    bundle exec bin/smoke_openai.rb hello in one word
    bundle exec bin/smoke_gemini.rb hello in one word

Each script supports the same flags:

    --model MODEL    override the default model for this provider
    --record DIR     after a successful live call, write request.json
                     and response.json to DIR
    --mock DIR       replay a recorded fixture from DIR instead of
                     making a live call (no API key needed)

### Choosing a model

Each script resolves the model in this order:

1. `--model` CLI flag, e.g. `--model claude-opus-4-7`
2. Provider-specific env var: `ANTHROPIC_MODEL`, `OPENAI_MODEL`, `GEMINI_MODEL`
3. Default from `reference/config/defaults.yml`

### Updating model defaults

Providers deprecate models over time. When a default model is retired,
update `reference/config/defaults.yml` and commit the change. This is
expected maintenance of the reference implementation and does not require
a spec version bump — the Harnas specification does not name specific
models.
