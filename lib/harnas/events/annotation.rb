# frozen_string_literal: true

module Harnas
  module Events
    # Payload type for an :annotation Event — the canonical annotative
    # sidecar. Middleware, strategies, or surfaces append annotations
    # to record derived state they want persisted with the Session
    # (e.g. a StaleReadGuard recording sha256 of each read).
    #
    # Projections MUST NOT include :annotation Events in the request
    # body sent to a Provider; they exist purely in the Log.
    #
    # `kind` is a dotted namespace identifying the annotation's owner,
    # e.g. "stale_read_guard.hash". `data` is an arbitrary JSON-plain
    # Hash the owner interprets.
    Annotation = Data.define(:kind, :data) do
      def initialize(kind:, data: {})
        raise ArgumentError, "kind must be a String"  unless kind.is_a?(String)
        raise ArgumentError, "kind must not be empty" if kind.empty?
        raise ArgumentError, "data must be a Hash"    unless data.is_a?(Hash)

        super
      end
    end
  end
end
