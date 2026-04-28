# 04 · builtin-tools

Demonstrates the shipped `Harnas::Tools::Builtin` library: canonical
tool implementations for the filesystem, shell, and HTTP that let
an agent do real work without the caller writing a handler from
scratch.

Demonstrates:

- A manifest that references tools by `harnas.builtin.*` symbolic
  names
- Passing `Harnas::Tools::Builtin.handlers` into
  `Harnas::Agent.from_manifest` to resolve those names
- A two-tool-call agent loop (`list_dir` → `read_file` → text reply)
  driven by a ScriptedProvider

## What ships in `Harnas::Tools::Builtin`

| Tool | Handler name | Purpose |
|---|---|---|
| `read_file` | `harnas.builtin.read_file` | Read the contents of a file |
| `write_file` | `harnas.builtin.write_file` | Write text to a file |
| `edit_file` | `harnas.builtin.edit_file` | Surgical find-and-replace (`replace_all:` optional) |
| `list_dir` | `harnas.builtin.list_dir` | List a directory's entries |
| `glob` | `harnas.builtin.glob` | Find files matching a glob pattern |
| `grep` | `harnas.builtin.grep` | Regex-search file contents (returns path:line:content) |
| `run_shell` | `harnas.builtin.run_shell` | Run a shell command (with timeout) |
| `fetch_url` | `harnas.builtin.fetch_url` | GET a URL, return the body |

These are intentionally low-level — no sandboxing, no path
restriction, no URL blocklist. Adopters that need safety layers
should compose them with permission strategies (`HumanApproval`,
`DenyByName`) or wrap the handlers before passing them to
`Agent.from_manifest`.

## Run

```sh
bundle exec ruby examples/04-builtin-tools/run.rb
```

## Expected output

```
agent: builtin-tools
---
assistant: The directory holds alpha.txt and beta.txt; alpha contains "contents of alpha".
---
log (7 events):
  seq 0  user_message         what's in /tmp/harnas-builtin-demo-…?
  seq 1  assistant_message
  seq 2  tool_use             list_dir({path:"/tmp/harnas-builtin-demo-…"})
  seq 3  tool_result          alpha.txt\nbeta.txt
  seq 4  assistant_message
  seq 5  tool_use             read_file({path:"/tmp/harnas-builtin-demo-…/alpha.txt"})
  seq 6  tool_result          contents of alpha
  seq 7  assistant_message    The directory holds alpha.txt and beta.txt …
```
