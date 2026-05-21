# frozen_string_literal: true

require "uri"

require "harnas/actions/allow"
require "harnas/actions/refuse"
require "harnas/hooks"

module Harnas
  module Strategies
    module Credential
      # Injects credentials into supported tool arguments immediately
      # before dispatch. The durable Log keeps the agent's original
      # arguments; injected values are never written to Log/Observation.
      class Proxy
        HEADER_TOOLS = %w[fetch_url].freeze
        CREDENTIAL_PATTERN = /\{credential\.([A-Za-z0-9_]+)\}/

        def self.install(session = nil, credentials: {}, routes: [])
          new(credentials: credentials, routes: routes).install(session&.hooks || Hooks)
        end

        def initialize(credentials: {}, routes: [])
          @credentials = validate_credentials(credentials)
          @routes = validate_routes(routes)
          @consecutive_missing = 0
        end

        def install(hooks = Hooks)
          handler = method(:on_pre_tool_use)
          hooks.on(:pre_tool_use, handler)
          handler
        end

        def on_pre_tool_use(session:, tool_use:, **_)
          rewritten = deep_copy(tool_use.payload[:arguments] || {})
          changed = false

          @routes.each_with_index do |route, index|
            next unless route_matches?(route, tool_use)

            decision = apply_route(session, route, index, rewritten)
            return decision if decision

            changed = true
          end

          changed ? Harnas::Actions::Allow.call.merge(arguments: rewritten) : Harnas::Actions::Allow.call
        end

        private

        def validate_credentials(credentials)
          unless credentials.is_a?(Hash)
            raise ArgumentError, "credential/proxy credentials must be an object"
          end

          credentials.each_with_object({}) do |(name, spec), out|
            unless spec.is_a?(Hash)
              raise ArgumentError, "credential #{name.inspect} must be an object"
            end

            from = fetch_string(spec, :from)
            unless %w[env literal].include?(from)
              raise ArgumentError,
                    "credential #{name.inspect} has unsupported from: #{from.inspect}"
            end

            out[name.to_s] = { from: from, name: spec[:name] || spec["name"],
                               value: spec[:value] || spec["value"] }
          end
        end

        def validate_routes(routes)
          raise ArgumentError, "credential/proxy routes must be an array" unless routes.is_a?(Array)

          routes.map.with_index do |route, index|
            validate_route(route, index)
          end
        end

        def validate_route(route, index)
          unless route.is_a?(Hash)
            raise ArgumentError, "credential/proxy route #{index} must be an object"
          end

          tool = fetch_string(route, :tool)
          raise ArgumentError, "credential/proxy route #{index} missing tool" if tool.to_s.empty?

          match = route[:match] || route["match"] || {}
          inject = route[:inject] || route["inject"]
          validate_route_objects!(match, inject, index)

          inject = validate_inject(inject, index)

          validate_url_match!(match, index)
          { tool: tool, match: match, inject: inject }
        end

        def validate_route_objects!(match, inject, index)
          unless match.is_a?(Hash)
            raise ArgumentError, "credential/proxy route #{index} match must be an object"
          end
          return if inject.is_a?(Hash)

          raise ArgumentError, "credential/proxy route #{index} inject must be an object"
        end

        def validate_inject(inject, index)
          into = fetch_string(inject, :into)
          unless into == "headers"
            raise ArgumentError,
                  "credential/proxy route #{index} only supports inject.into=headers"
          end

          key = fetch_string(inject, :key)
          value = fetch_string(inject, :value)
          if key.empty? || value.empty?
            raise ArgumentError, "credential/proxy route #{index} missing inject key/value"
          end

          { into: into, key: key, value: value }
        end

        def validate_url_match!(match, index)
          matchers = %i[url_host url_host_glob].count do |key|
            match.key?(key) || match.key?(key.to_s)
          end
          return unless matchers > 1

          raise ArgumentError, "credential/proxy route #{index} may use only one URL matcher"
        end

        def route_matches?(route, tool_use)
          return false unless tool_use.payload[:name] == route[:tool]

          match = route[:match]
          return true if match.empty?

          host = url_host(tool_use.payload[:arguments] || {})
          exact = match[:url_host] || match["url_host"]
          glob = match[:url_host_glob] || match["url_host_glob"]
          return host == exact.to_s if exact
          return File.fnmatch?(glob.to_s, host.to_s, File::FNM_EXTGLOB) if glob

          true
        end

        def url_host(args)
          raw_url = args[:url] || args["url"]
          URI.parse(raw_url.to_s).host
        rescue URI::InvalidURIError
          nil
        end

        def resolve_template(template)
          used = []
          missing = nil
          value = template.gsub(CREDENTIAL_PATTERN) do
            name = Regexp.last_match(1)
            resolved = resolve_credential(name)
            if resolved.nil?
              missing = name
              ""
            else
              used << name
              resolved
            end
          end
          [value, used.uniq, missing]
        end

        def resolve_credential(name)
          spec = @credentials[name]
          return nil unless spec

          case spec[:from]
          when "literal" then spec[:value]
          when "env" then ENV.fetch(spec[:name].to_s, nil)
          end
        end

        def apply_route(session, route, index, rewritten)
          unless HEADER_TOOLS.include?(route[:tool])
            append_runtime_error!(
              session,
              "credential_proxy_unsupported_tool",
              "credential/proxy route matched unsupported tool '#{route[:tool]}'"
            )
            return Harnas::Actions::Refuse.call(reason: "credential_proxy_unsupported_tool")
          end

          value, used, missing = resolve_template(route[:inject][:value])
          return missing_credential(session, route, missing) if missing

          headers = string_hash(rewritten[:headers] || rewritten["headers"] || {})
          headers[route[:inject][:key]] = value
          rewritten[:headers] = headers
          @consecutive_missing = 0
          append_annotation(session, route, index, used)
          nil
        end

        def missing_credential(session, route, name)
          @consecutive_missing += 1
          if @consecutive_missing >= 3
            append_runtime_error!(session, "credential_proxy_missing_persistent",
                                  "credential '#{name}' is persistently unavailable")
            raise Harnas::Hooks::TurnFailed, "credential_proxy_missing_persistent"
          end

          Harnas::Actions::Refuse.call(
            reason: "credential '#{name}' is not available; required by " \
                    "credential/proxy route matching tool '#{route[:tool]}'"
          )
        end

        def append_annotation(session, route, index, used)
          session.log.append(
            type: :annotation,
            payload: {
              kind: "credential_injected",
              tool: route[:tool],
              route_index: index,
              credentials_used: used
            }
          )
        end

        def append_runtime_error!(session, reason, message)
          session.log.append(
            type: :runtime_error,
            payload: {
              source: "strategy",
              handler: "credential/proxy",
              error_class: "Harnas::CredentialProxyError",
              message: message,
              reason: reason,
              terminal: true
            }
          )
        end

        def fetch_string(hash, key)
          (hash[key] || hash[key.to_s]).to_s
        end

        def string_hash(value)
          unless value.is_a?(Hash)
            raise ArgumentError, "credential/proxy headers argument must be an object"
          end

          value.each_with_object({}) { |(key, item), out| out[key.to_s] = item.to_s }
        end

        def deep_copy(value)
          Marshal.load(Marshal.dump(value))
        end
      end
    end
  end
end
