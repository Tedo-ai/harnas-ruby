# frozen_string_literal: true

require "harnas/hooks"
require "harnas/actions/allow"
require "harnas/actions/request_approval"

module Harnas
  module Strategies
    module Permission
      # Hold tool calls whose name is in a configured hold-list for
      # async human approval (spec/07-permission.md R7-R11).
      #
      # ## Arbitrary choices
      #
      # - Hook: :pre_tool_use
      # - Predicate: tool_use.payload[:name] in hold-list
      # - Action: Actions::RequestApproval (with the tool name in
      #   reason) or Actions::Allow
      class RequireApproval
        # Normative default mirroring DenyByName's format convention.
        DEFAULT_REASON_FORMAT = "tool $NAME requires approval"

        def self.install(session = nil, names:, reason_format: DEFAULT_REASON_FORMAT)
          new(names: names, reason_format: reason_format).install(session&.hooks || Hooks)
        end

        def initialize(names:, reason_format: DEFAULT_REASON_FORMAT)
          raise ArgumentError, "names must be a non-empty Array of Strings" \
            unless names.is_a?(Array) && !names.empty? && names.all?(String)
          raise ArgumentError, "reason_format must be a String" \
            unless reason_format.is_a?(String)

          @holdlist      = names.to_set
          @reason_format = reason_format
        end

        def install(hooks = Hooks)
          handler = method(:on_pre_tool_use)
          hooks.on(:pre_tool_use, handler)
          handler
        end

        def on_pre_tool_use(tool_use:, **_)
          name = tool_use.payload[:name]
          if @holdlist.include?(name)
            Harnas::Actions::RequestApproval.call(
              reason: @reason_format.gsub("$NAME", name.inspect),
              requested_by: "Permission::RequireApproval"
            )
          else
            Harnas::Actions::Allow.call
          end
        end
      end
    end
  end
end
