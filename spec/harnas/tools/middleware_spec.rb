# frozen_string_literal: true

require "stringio"
require "harnas/tools/middleware"
require "harnas/observation"

RSpec.describe Harnas::Tools::Middleware do
  describe ".timed" do
    it "returns a lambda that calls the wrapped handler and returns its result" do
      handler = ->(args) { "hello #{args[:name]}" }
      wrapped = described_class.timed(handler, name: "greet")
      expect(wrapped.call(name: "world")).to eq("hello world")
    end

    it "emits :tool_timed on successful call" do
      handler = ->(_args) { "ok" }
      wrapped = described_class.timed(handler, name: "fast")

      events = []
      Harnas::Observation.subscribe(lambda { |ev, payload|
        events << [ev, payload] if ev == :tool_timed
      })

      wrapped.call({})
      expect(events.size).to eq(1)
      name, payload = events.first
      expect(name).to eq(:tool_timed)
      expect(payload[:outcome]).to eq(:ok)
      expect(payload[:name]).to eq("fast")
      expect(payload[:duration_ms]).to be >= 0
    ensure
      Harnas::Observation.reset!
    end

    it "emits :tool_timed with :error outcome on failure, and re-raises" do
      handler = ->(_args) { raise "boom" }
      wrapped = described_class.timed(handler, name: "crashy")

      events = []
      Harnas::Observation.subscribe(->(ev, payload) { events << payload if ev == :tool_timed })

      expect { wrapped.call({}) }.to raise_error(RuntimeError, "boom")
      expect(events.first[:outcome]).to eq(:error)
      expect(events.first[:error]).to eq("RuntimeError")
    ensure
      Harnas::Observation.reset!
    end
  end

  describe ".logged" do
    it "writes a one-line trace before and after a successful call" do
      io = StringIO.new
      handler = ->(_args) { "result" }
      wrapped = described_class.logged(handler, name: "echo", io: io)

      wrapped.call(a: 1)
      io.rewind
      lines = io.read.lines
      expect(lines.size).to eq(2)
      expect(lines[0]).to include("call", "{a: 1}")
      expect(lines[1]).to include("ok", "result")
    end

    it "logs errors and re-raises" do
      io = StringIO.new
      handler = ->(_args) { raise ArgumentError, "bad input" }
      wrapped = described_class.logged(handler, name: "bad", io: io)

      expect { wrapped.call({}) }.to raise_error(ArgumentError)
      io.rewind
      expect(io.read).to include("err", "ArgumentError", "bad input")
    end

    it "truncates the preview to preview_bytes" do
      io = StringIO.new
      handler = ->(_args) { "x" * 500 }
      wrapped = described_class.logged(handler, name: "big", io: io, preview_bytes: 20)

      wrapped.call({})
      io.rewind
      # result line should carry exactly 20 chars of x plus the ellipsis.
      expect(io.read).to include("#{"x" * 20}…")
    end
  end

  describe ".retried" do
    let(:no_backoff) { ->(_) { 0 } }

    it "returns a lambda that retries on matching exceptions" do
      calls = 0
      handler = lambda do |_args|
        calls += 1
        raise "fail" if calls < 3

        "ok"
      end
      wrapped = described_class.retried(
        handler, attempts: 3, on: [RuntimeError], backoff_ms: no_backoff
      )

      expect(wrapped.call({})).to eq("ok")
      expect(calls).to eq(3)
    end

    it "raises after attempts are exhausted" do
      handler = ->(_args) { raise "always" }
      wrapped = described_class.retried(
        handler, attempts: 2, on: [RuntimeError], backoff_ms: no_backoff
      )

      expect { wrapped.call({}) }.to raise_error(RuntimeError, "always")
    end

    it "does not retry exceptions not in :on" do
      calls = 0
      handler = lambda do |_args|
        calls += 1
        raise ArgumentError, "no retry"
      end
      wrapped = described_class.retried(
        handler, attempts: 5, on: [RuntimeError], backoff_ms: no_backoff
      )

      expect { wrapped.call({}) }.to raise_error(ArgumentError)
      expect(calls).to eq(1)
    end

    it "rejects attempts < 1" do
      expect { described_class.retried(->(_) {}, attempts: 0) }
        .to raise_error(ArgumentError, /attempts/)
    end
  end

  describe described_class::RateLimiter do
    it "admits calls up to the per-minute budget" do
      limiter = described_class.new(per_minute: 2)
      handler = limiter.wrap(->(_args) { "ok" })

      expect(handler.call({})).to eq("ok")
      expect(handler.call({})).to eq("ok")
    end

    it "raises RateLimitExceeded when the budget is exhausted" do
      limiter = described_class.new(per_minute: 1)
      handler = limiter.wrap(->(_args) { "ok" })

      handler.call({})
      expect { handler.call({}) }
        .to raise_error(described_class::RateLimitExceeded, /1 per minute/)
    end

    it "shares its budget across multiple wrapped handlers" do
      limiter = described_class.new(per_minute: 2)
      a = limiter.wrap(->(_args) { "a" })
      b = limiter.wrap(->(_args) { "b" })

      expect(a.call({})).to eq("a")
      expect(b.call({})).to eq("b")
      expect { a.call({}) }.to raise_error(described_class::RateLimitExceeded)
    end

    it "rejects a non-positive per_minute" do
      expect { described_class.new(per_minute: 0) }
        .to raise_error(ArgumentError, /per_minute/)
    end
  end

  describe "composition" do
    it "stacks multiple middlewares cleanly" do
      io = StringIO.new
      handler = ->(_args) { "result" }
      wrapped = described_class.timed(
        described_class.logged(handler, name: "stacked", io: io)
      )

      events = []
      Harnas::Observation.subscribe(->(ev, p) { events << p if ev == :tool_timed })

      wrapped.call({})
      io.rewind
      expect(io.read).to include("call", "ok")
      expect(events.size).to eq(1)
    ensure
      Harnas::Observation.reset!
    end
  end
end
