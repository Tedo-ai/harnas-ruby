# frozen_string_literal: true

module Harnas
  module Events
    # Payload type for a :provider_error Event — captures a failure of
    # the Provider.call seam (HTTP error, timeout, network failure,
    # malformed response). Appended to the Log by AgentLoop when a
    # provider call fails; if a retry policy lets the loop recover, the
    # entry is non-terminal and a successful response follows. If the
    # policy gives up, the entry is terminal and the loop ends with
    # reason :provider_failed.
    #
    # Projections MUST NOT include :provider_error events in the request
    # body sent to a Provider — they are part of the Log substrate, not
    # the agent's conversation. (R7 of spec/01-overview.md applies to
    # this annotative-class event the same as to :annotation.)
    ProviderError = Data.define(:provider, :status, :error_class, :message,
                                :attempt, :terminal) do
      def initialize(provider:, error_class:, message:, attempt:, terminal:,
                     status: nil)
        raise ArgumentError, "provider must be a Symbol or String" \
          unless provider.is_a?(Symbol) || provider.is_a?(String)
        raise ArgumentError, "error_class must be a String"   unless error_class.is_a?(String)
        raise ArgumentError, "message must be a String"       unless message.is_a?(String)
        raise ArgumentError, "attempt must be a positive Integer" \
          unless attempt.is_a?(Integer) && attempt.positive?
        raise ArgumentError, "terminal must be true or false" \
          unless [true, false].include?(terminal)
        raise ArgumentError, "status must be nil or an Integer" \
          unless status.nil? || status.is_a?(Integer)

        super
      end
    end
  end
end
