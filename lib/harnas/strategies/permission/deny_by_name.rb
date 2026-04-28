# frozen_string_literal: true

require "harnas/hooks"
require "harnas/actions/allow"
require "harnas/actions/refuse"

module Harnas
  module Strategies
    module Permission
      # Deny tool calls whose name is in a configured deny-list.
      #
      # ## Arbitrary choices
      #
      # - Hook: :pre_tool_use
      # - Predicate: tool_use.payload[:name] in denylist
      # - Action: Actions::Refuse (with the tool name in reason) or
      #   Actions::Allow
      #
      # Pure name-match; does not inspect arguments. For
      # argument-aware gating, write a custom strategy (still ~30
      # lines — it's just Ruby plus the shared Actions).
      class DenyByName
        # Normative default per spec/strategies/permission/deny-by-name.md.
        # $NAME is substituted with the tool's name (inspected, i.e.
        # wrapped in quotes).
        DEFAULT_REASON_FORMAT = "tool $NAME is on the deny-list"

        def self.install(session = nil, names:, reason_format: DEFAULT_REASON_FORMAT)
          new(names: names, reason_format: reason_format).install(session&.hooks || Hooks)
        end

        def initialize(names:, reason_format: DEFAULT_REASON_FORMAT)
          raise ArgumentError, "names must be a non-empty Array of Strings" \
            unless names.is_a?(Array) && !names.empty? && names.all?(String)
          raise ArgumentError, "reason_format must be a String" \
            unless reason_format.is_a?(String)

          @denylist       = names.to_set
          @reason_format  = reason_format
        end

        def install(hooks = Hooks)
          handler = method(:on_pre_tool_use)
          hooks.on(:pre_tool_use, handler)
          handler
        end

        def on_pre_tool_use(tool_use:, **_)
          name = tool_use.payload[:name]
          if @denylist.include?(name)
            Harnas::Actions::Refuse.call(
              reason: @reason_format.gsub("$NAME", name.inspect)
            )
          else
            Harnas::Actions::Allow.call
          end
        end
      end
    end
  end
end
