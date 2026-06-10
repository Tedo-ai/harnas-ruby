# frozen_string_literal: true

require "harnas/web/security"

RSpec.describe Harnas::Web::Security do
  describe ".require_auth_token!" do
    it "allows loopback hosts without a token" do
      expect { described_class.require_auth_token!("127.0.0.1", nil) }.not_to raise_error
      expect { described_class.require_auth_token!("localhost", "") }.not_to raise_error
    end

    it "requires a token for non-loopback hosts" do
      expect { described_class.require_auth_token!("0.0.0.0", nil) }
        .to raise_error(ArgumentError, /requires --auth-token/)
    end
  end

  describe ".authorized_request?" do
    it "allows requests when no token is configured" do
      expect(described_class.authorized_request?({}, nil)).to be(true)
    end

    it "accepts bearer and query tokens" do
      bearer_env = { "HTTP_AUTHORIZATION" => "Bearer secret" }
      expect(described_class.authorized_request?(bearer_env, "secret"))
        .to be(true)
      expect(described_class.authorized_request?({ "QUERY_STRING" => "token=secret" }, "secret"))
        .to be(true)
    end

    it "rejects missing or incorrect tokens" do
      expect(described_class.authorized_request?({}, "secret")).to be(false)
      bearer_env = { "HTTP_AUTHORIZATION" => "Bearer wrong" }
      expect(described_class.authorized_request?(bearer_env, "secret"))
        .to be(false)
    end
  end
end
