# 03 · provider-switch

The headline claim of Harnas, made concrete: the Log is sovereign
and provider-agnostic. The same append-only event Log renders into
three completely different wire shapes depending on which projection
is invoked. The conversation state does not change; only the shape
of the request body sent to the provider.

Demonstrates:

- Driving a multi-turn conversation against one provider
- Projecting the resulting Log into Anthropic, OpenAI, and Gemini
  request bodies from the same Session
- The structural difference between provider APIs (Anthropic +
  OpenAI share `role/content`; Gemini uses `role/parts[]`)

## Run

```sh
bundle exec ruby examples/03-provider-switch/run.rb
```

## Expected output

The Log is four events (two user/assistant pairs). The printed
output shows:

- Anthropic: `[{role:"user",content:"…"}, {role:"assistant",content:"…"}, …]`
- OpenAI:    the same `role/content` shape (Chat Completions API)
- Gemini:    `[{role:"user",parts:[{text:"…"}]}, {role:"model",parts:[{text:"…"}]}, …]`

All three are derived from one immutable Log. A real deployment
swapping providers mid-conversation uses the same mechanism: stop
using Projection A, start using Projection B, the Log is untouched.

## Why this is the point

Most agent frameworks conflate the state of the conversation with
the request body sent to the provider. When you switch providers,
you rewrite the state (and usually lose fidelity in the
translation). Harnas defines the Log as the canonical state and
projection as the separate, per-provider concern. Provider
portability is a property of the design, not a promise of the
marketing.
