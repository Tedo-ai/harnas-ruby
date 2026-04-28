# frozen_string_literal: true

require "harnas/providers/retry_policy"
require "harnas/providers/errors"

RSpec.describe Harnas::Providers::RetryPolicy do
  let(:policy) { described_class.new }

  describe "default policy" do
    it "retries HTTP 429 with a backoff" do
      err = Harnas::Providers::HTTPError.new(429, { error: "rate limited" })
      decision = policy.decide(err, 1)
      expect(decision[0]).to eq(:retry)
      expect(decision[1]).to be > 0
    end

    it "retries HTTP 503 with a backoff" do
      err = Harnas::Providers::HTTPError.new(503, "Service Unavailable")
      expect(policy.decide(err, 1)[0]).to eq(:retry)
    end

    it "aborts on HTTP 400" do
      err = Harnas::Providers::HTTPError.new(400, "bad request")
      expect(policy.decide(err, 1)).to eq(:abort)
    end

    it "aborts on HTTP 404" do
      err = Harnas::Providers::HTTPError.new(404, "not found")
      expect(policy.decide(err, 1)).to eq(:abort)
    end

    it "aborts on HTTP 401" do
      err = Harnas::Providers::HTTPError.new(401, "unauthorized")
      expect(policy.decide(err, 1)).to eq(:abort)
    end

    it "retries Errno::ECONNRESET" do
      err = Errno::ECONNRESET.new
      expect(policy.decide(err, 1)[0]).to eq(:retry)
    end

    it "aborts on ArgumentError (a non-network bug)" do
      expect(policy.decide(ArgumentError.new("bad"), 1)).to eq(:abort)
    end
  end

  describe "max_attempts" do
    it "aborts when attempt reaches max_attempts even on retryable errors" do
      tight = described_class.new(max_attempts: 2)
      err   = Harnas::Providers::HTTPError.new(503, "")

      expect(tight.decide(err, 1)[0]).to eq(:retry)
      expect(tight.decide(err, 2)).to eq(:abort)
    end

    it "rejects max_attempts < 1" do
      expect { described_class.new(max_attempts: 0) }
        .to raise_error(ArgumentError, /max_attempts/)
    end
  end

  describe "backoff curve" do
    it "grows exponentially by default" do
      err = Harnas::Providers::HTTPError.new(503, "")
      first  = policy.decide(err, 1)[1]
      second = policy.decide(err, 2)[1]
      expect(second).to be > first
    end

    it "honors a caller-supplied backoff_ms proc" do
      flat = described_class.new(backoff_ms: ->(_attempt) { 7 })
      expect(flat.decide(Harnas::Providers::HTTPError.new(503, ""), 1)).to eq([:retry, 7])
    end
  end

  describe "configurable retryable_http" do
    it "treats only the listed statuses as retryable" do
      narrow = described_class.new(retryable_http: [429])
      expect(narrow.decide(Harnas::Providers::HTTPError.new(429, ""), 1)[0]).to eq(:retry)
      expect(narrow.decide(Harnas::Providers::HTTPError.new(500, ""), 1)).to eq(:abort)
    end
  end
end
