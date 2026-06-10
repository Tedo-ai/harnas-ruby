# frozen_string_literal: true

require "rack"

module Harnas
  module Web
    # Authentication helpers for the optional web inspector. The web
    # inspector is development tooling; when exposed beyond loopback it
    # must be protected by an explicit bearer token.
    module Security
      LOOPBACK_HOSTS = ["127.0.0.1", "::1", "localhost"].freeze

      module_function

      def loopback_host?(host)
        LOOPBACK_HOSTS.include?(host.to_s)
      end

      def require_auth_token!(host, token)
        return if loopback_host?(host)
        return unless token.to_s.empty?

        raise ArgumentError,
              "harnas web inspector requires --auth-token or HARNAS_WEB_AUTH_TOKEN " \
              "when binding to non-loopback host #{host.inspect}"
      end

      def authorized_request?(env, token)
        token = token.to_s
        return true if token.empty?

        request = Rack::Request.new(env)
        bearer = env["HTTP_AUTHORIZATION"].to_s
        bearer == "Bearer #{token}" || request.params["token"].to_s == token
      end

      def unauthorized_response
        [
          401,
          {
            "content-type" => "text/plain",
            "www-authenticate" => 'Bearer realm="harnas-web"'
          },
          ["unauthorized"]
        ]
      end
    end
  end
end
