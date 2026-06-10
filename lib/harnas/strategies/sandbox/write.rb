# frozen_string_literal: true

require "pathname"

require "harnas/actions/allow"
require "harnas/actions/refuse"
require "harnas/hooks"

module Harnas
  module Strategies
    module Sandbox
      # Tool-boundary write guard for write_file/edit_file. This is not
      # an OS-level sandbox; shell commands are outside its reach.
      class Write
        DEFAULT_ALLOW = ["."].freeze
        WRITE_TOOLS = %w[write_file edit_file].freeze

        def self.install(session = nil, allow: DEFAULT_ALLOW, deny: [])
          new(allow: allow, deny: deny).install(session&.hooks || Hooks)
        end

        def initialize(allow: DEFAULT_ALLOW, deny: [])
          @allow_labels = Array(allow)
          @deny_labels = Array(deny)
          @allow = normalize_list(@allow_labels)
          @deny = normalize_list(@deny_labels)
          @consecutive_violations = 0
        end

        def install(hooks = Hooks)
          handler = method(:on_pre_tool_use)
          hooks.on(:pre_tool_use, handler)
          handler
        end

        def on_pre_tool_use(session:, tool_use:, **_)
          return Harnas::Actions::Allow.call unless WRITE_TOOLS.include?(tool_use.payload[:name])

          path = tool_use.payload.dig(:arguments, :path) ||
                 tool_use.payload.dig(:arguments, "path")
          return Harnas::Actions::Allow.call unless path

          normalized = normalize(path)
          if allowed?(normalized) && !denied?(normalized)
            @consecutive_violations = 0
            return Harnas::Actions::Allow.call
          end

          @consecutive_violations += 1
          abort_after_limit!(session) if @consecutive_violations >= 3
          Harnas::Actions::Refuse.call(reason: message(path))
        end

        private

        def normalize_list(values)
          values.map { |value| normalize(value) }
        end

        def normalize(value)
          path = Pathname.new(value.to_s)
          path = Pathname.pwd.join(path) unless path.absolute?
          realpath_with_missing_leaf(path.cleanpath)
        end

        def realpath_with_missing_leaf(path)
          return path.realpath.to_s if path.exist?

          parent = path.parent
          return parent.realpath.join(path.basename).to_s if parent.exist?

          path.to_s
        rescue Errno::ENOENT
          path.to_s
        end

        def denied?(path)
          @deny.any? { |prefix| path == prefix || path.start_with?("#{prefix}/") }
        end

        def allowed?(path)
          @allow.any? { |prefix| path == prefix || path.start_with?("#{prefix}/") }
        end

        def message(path)
          "Write to '#{path}' is not permitted. Allowed paths: #{format_list(@allow_labels)}. " \
            "Denied paths: #{format_list(@deny_labels)}."
        end

        def format_list(values)
          "[#{values.map { |value| "'#{value}'" }.join(", ")}]"
        end

        def abort_after_limit!(session)
          session.log.append(
            type: :runtime_error,
            payload: {
              source: "strategy",
              handler: "sandbox/write",
              error_class: "Harnas::SandboxViolation",
              message: "sandbox_violation_limit",
              reason: "sandbox_violation_limit",
              terminal: true
            }
          )
          raise Harnas::Hooks::TurnFailed, "sandbox_violation_limit"
        end
      end
    end
  end
end
