# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"
require "harnas/cli"

RSpec.describe Harnas::CLI do
  def write_manifest(dir, manifest)
    path = File.join(dir, "manifest.json")
    File.write(path, JSON.pretty_generate(manifest))
    path
  end

  def basic_manifest(overrides = {})
    {
      "harnas_version" => "0.1",
      "name" => "cli-test",
      "provider" => {
        "kind" => "mock",
        "model" => "mock-test",
        "max_tokens" => 1024
      },
      "tools" => [],
      "strategies" => []
    }.merge(overrides)
  end

  def run_cli(argv, stdin: "", env: {})
    stdout = StringIO.new
    stderr = StringIO.new
    status = described_class.new(
      argv: argv,
      stdin: StringIO.new(stdin),
      stdout: stdout,
      stderr: stderr,
      env: env
    ).run
    [status, stdout.string, stderr.string]
  end

  around do |example|
    Dir.mktmpdir("harnas-cli-home-") do |home|
      @home = home
      example.run
    end
  end

  it "runs one prompt against a manifest and saves the session" do
    Dir.mktmpdir("harnas-cli-") do |dir|
      manifest = write_manifest(dir, basic_manifest)
      status, stdout, stderr = run_cli(
        ["run", manifest, "--input", "hello"],
        env: { "HOME" => @home }
      )

      expect(status).to eq(0)
      expect(stdout).to eq("ok\n")
      expect(stderr).to include("saved: ")
      expect(Dir.glob(File.join(@home, ".harnas", "runs", "*-cli-test.jsonl")).size).to eq(1)
    end
  end

  it "runs an interactive chat until exit" do
    Dir.mktmpdir("harnas-cli-") do |dir|
      manifest = write_manifest(dir, basic_manifest)
      status, stdout, _stderr = run_cli(
        ["chat", manifest],
        stdin: "hello\nexit\n",
        env: { "HOME" => @home }
      )

      expect(status).to eq(0)
      expect(stdout).to include("harnas chat")
      expect(stdout).to include("ok")
      expect(Dir.glob(File.join(@home, ".harnas", "runs", "*-cli-test.jsonl")).size).to eq(1)
    end
  end

  it "applies provider and model overrides before loading the agent" do
    Dir.mktmpdir("harnas-cli-") do |dir|
      manifest = write_manifest(dir, basic_manifest)
      session = Harnas::Session.create
      fake_agent = instance_double(
        Harnas::Agent,
        name: "cli-test",
        session: session,
        log: session.log,
        chat: Harnas::Agent::Response.new(
          text: "ok", stop_reason: :end_turn, usage: {}, log: session.log
        )
      )
      expect(Harnas::Agent).to receive(:from_manifest) do |loaded_manifest, **kwargs|
        expect(loaded_manifest["provider"]).to include(
          "kind" => "anthropic",
          "model" => "claude-test"
        )
        expect(kwargs[:api_keys]).to include(anthropic: "sk-test")
        fake_agent
      end

      status, stdout, stderr = run_cli(
        ["run", manifest, "--provider", "anthropic", "--model", "claude-test", "--input", "hi"],
        env: { "HOME" => @home, "ANTHROPIC_API_KEY" => "sk-test" }
      )

      expect(status).to eq(0)
      expect(stdout).to eq("ok\n")
      expect(stderr).to include("saved: ")
    end
  end

  it "automatically resolves built-in tool handlers declared by a manifest" do
    manifest_hash = basic_manifest(
      "tools" => [
        {
          "name" => "list_dir",
          "handler" => "harnas.builtin.list_dir",
          "description" => "List entries in a directory.",
          "input_schema" => {
            "type" => "object",
            "properties" => { "path" => { "type" => "string" } },
            "required" => ["path"]
          }
        }
      ]
    )

    Dir.mktmpdir("harnas-cli-") do |dir|
      manifest = write_manifest(dir, manifest_hash)
      status, stdout, _stderr = run_cli(
        ["run", manifest, "--input", "hi"],
        env: { "HOME" => @home }
      )

      expect(status).to eq(0)
      expect(stdout).to eq("ok\n")
    end
  end

  it "prints terminal provider errors and exits nonzero for one-shot runs" do
    Dir.mktmpdir("harnas-cli-") do |dir|
      manifest = write_manifest(dir, basic_manifest)
      session = Harnas::Session.create
      session.log.append(
        type: :provider_error,
        payload: {
          provider: :anthropic,
          status: 503,
          error_class: "Harnas::Providers::HTTPError",
          message: "HTTP 503: unavailable",
          attempt: 1,
          terminal: true
        }
      )
      fake_agent = instance_double(
        Harnas::Agent,
        name: "cli-test",
        session: session,
        log: session.log,
        chat: Harnas::Agent::Response.new(
          text: "", stop_reason: nil, usage: {}, log: session.log
        )
      )
      allow(Harnas::Agent).to receive(:from_manifest).and_return(fake_agent)

      status, stdout, stderr = run_cli(
        ["run", manifest, "--input", "hello"],
        env: { "HOME" => @home }
      )

      expect(status).to eq(2)
      expect(stdout).to eq("")
      expect(stderr).to include("provider error: HTTP 503: unavailable")
    end
  end

  it "inspects a saved session as a compact timeline" do
    Dir.mktmpdir("harnas-cli-") do |dir|
      session = Harnas::Session.new(id: "ses_inspect", metadata: { label: "demo" })
      session.log.append(type: :user_message, payload: { text: "hello" })
      session.log.append(
        type: :assistant_message,
        payload: { text: "hi there", stop_reason: :end_turn, usage: {} }
      )
      path = File.join(dir, "session.jsonl")
      session.save(path)

      status, stdout, stderr = run_cli(["inspect", path])

      expect(status).to eq(0)
      expect(stderr).to eq("")
      expect(stdout).to include("session ses_inspect")
      expect(stdout).to include("metadata {\"label\":\"demo\"}")
      expect(stdout).to include("counts {\"assistant_message\":1,\"user_message\":1}")
      expect(stdout).to include("0  user_message")
      expect(stdout).to include("1  assistant_message")
    end
  end

  it "inspects a saved session as JSON" do
    Dir.mktmpdir("harnas-cli-") do |dir|
      session = Harnas::Session.new(id: "ses_json", metadata: {})
      session.log.append(type: :user_message, payload: { text: "hello" })
      path = File.join(dir, "session.jsonl")
      session.save(path)

      status, stdout, _stderr = run_cli(["inspect", path, "--json"])
      parsed = JSON.parse(stdout)

      expect(status).to eq(0)
      expect(parsed.fetch("session").fetch("id")).to eq("ses_json")
      expect(parsed.fetch("event_counts")).to eq("user_message" => 1)
      expect(parsed.fetch("events").first).to include(
        "seq" => 0,
        "type" => "user_message",
        "summary" => "hello"
      )
    end
  end
end
