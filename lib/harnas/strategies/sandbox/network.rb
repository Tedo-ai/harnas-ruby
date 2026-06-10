# frozen_string_literal: true

require "uri"

require "harnas/actions/allow"
require "harnas/actions/refuse"
require "harnas/hooks"

module Harnas
  module Strategies
    module Sandbox
      # Tool-boundary network guard for fetch_url. This is not an
      # OS-level sandbox; shell commands are outside its reach.
      class Network
        NETWORK_TOOLS = %w[fetch_url].freeze

        def self.install(session = nil, allow: [], deny: [])
          new(allow: allow, deny: deny).install(session&.hooks || Hooks)
        end

        def initialize(allow: [], deny: [])
          @allow = Array(allow).map(&:to_s)
          @deny = Array(deny).map(&:to_s)
          @consecutive_violations = 0
        end

        def install(hooks = Hooks)
          handler = method(:on_pre_tool_use)
          hooks.on(:pre_tool_use, handler)
          handler
        end

        def on_pre_tool_use(session:, tool_use:, **_)
          return Harnas::Actions::Allow.call unless NETWORK_TOOLS.include?(tool_use.payload[:name])

          raw_url = tool_use.payload.dig(:arguments, :url) ||
                    tool_use.payload.dig(:arguments, "url")
          host = parse_host(raw_url)
          unless host
            @consecutive_violations += 1
            abort_after_limit!(session) if @consecutive_violations >= 3
            return Harnas::Actions::Refuse.call(
              reason: "Network call has an unparseable URL and is not permitted."
            )
          end

          if @allow.include?(host) && !@deny.include?(host)
            @consecutive_violations = 0
            return Harnas::Actions::Allow.call
          end

          @consecutive_violations += 1
          abort_after_limit!(session) if @consecutive_violations >= 3
          Harnas::Actions::Refuse.call(reason: message(host))
        end

        private

        def parse_host(raw_url)
          URI.parse(raw_url.to_s).host
        rescue URI::InvalidURIError
          nil
        end

        def message(host)
          "Network call to '#{host}' is not permitted. Allowed hosts: #{format_list(@allow)}."
        end

        def format_list(values)
          "[#{values.map { |value| "'#{value}'" }.join(", ")}]"
        end

        def abort_after_limit!(session)
          session.log.append(
            type: :runtime_error,
            payload: {
              source: "strategy",
              handler: "sandbox/network",
              error_class: "Harnas::SandboxViolation",
              message: "sandbox_network_violation_limit",
              reason: "sandbox_network_violation_limit",
              terminal: true
            }
          )
          raise Harnas::Hooks::TurnFailed, "sandbox_network_violation_limit"
        end
      end
    end
  end
end
