# frozen_string_literal: true

require "harnas/events/tool_result"

module Harnas
  # Host-side resolution of async approvals (spec/07-permission.md R9).
  #
  # A run that ended with the :awaiting_approval outcome left one or
  # more tool_use Events un-executed, each marked by an
  # :approval_requested Event. Resolve them here BEFORE re-entering
  # AgentLoop#run so the next provider call sees a valid
  # assistant -> tool_result pairing.
  module Approval
    # Approve: append :approval_resolved, then execute exactly that
    # tool_use exactly once via the Runner (bypassing :pre_tool_use —
    # the decision was resolved by the host) and append its ordinary
    # :tool_result.
    def self.approve(session:, runner:, tool_use_id:, resolved_by: nil, reason: nil)
      tool_use = unresolved_tool_use!(session, tool_use_id)
      append_resolution(session, tool_use_id, "approved", reason: reason, resolved_by: resolved_by)
      runner.run(tool_use, into_log: session.log, session: session)
      nil
    end

    # Deny: append :approval_resolved followed by the synthesized
    # rejection :tool_result carrying the approval envelope.
    def self.deny(session:, tool_use_id:, reason:, resolved_by: nil)
      unresolved_tool_use!(session, tool_use_id)
      append_resolution(session, tool_use_id, "denied", reason: reason, resolved_by: resolved_by)
      session.log.append(
        type: :tool_result,
        payload: Events::ToolResult.new(
          tool_use_id: tool_use_id,
          error: "denied by approval: #{reason}",
          approval: { decision: "rejected", rule_matched: reason, applied_diff: nil }
        ).to_h
      )
      nil
    end

    def self.unresolved_tool_use!(session, tool_use_id)
      tool_use = nil
      session.log.each do |event|
        id = event.payload[:id] || event.payload["id"]
        result_id = event.payload[:tool_use_id] || event.payload["tool_use_id"]
        tool_use = event if event.type == :tool_use && id == tool_use_id
        if event.type == :tool_result && result_id == tool_use_id
          raise ArgumentError, "tool_use #{tool_use_id.inspect} already has a tool_result; " \
                               "approvals resolve exactly once"
        end
      end
      unless tool_use
        raise ArgumentError,
              "no tool_use with id #{tool_use_id.inspect} in the session log"
      end

      tool_use
    end
    private_class_method :unresolved_tool_use!

    def self.append_resolution(session, tool_use_id, decision, reason:, resolved_by:)
      session.log.append(
        type: :approval_resolved,
        payload: {
          tool_use_id: tool_use_id,
          decision: decision,
          reason: reason,
          resolved_by: resolved_by
        }
      )
    end
    private_class_method :append_resolution
  end
end
