# frozen_string_literal: true

require "harnas/strategies/compaction/token_marker_tail"
require "harnas/session"
require "harnas/events/user_message"
require "harnas/events/assistant_message"

RSpec.describe Harnas::Strategies::Compaction::TokenMarkerTail do
  let(:session) { Harnas::Session.create }

  def append_user_with_text(session, text)
    session.log.append(
      type: :user_message,
      payload: Harnas::Events::UserMessage.new(text: text).to_h
    )
  end

  describe "construction" do
    it "rejects non-positive max_tokens" do
      expect { described_class.new(max_tokens: 0, threshold: 0.5, keep_recent: 1) }
        .to raise_error(ArgumentError, /max_tokens must be a positive Integer/)
    end

    it "rejects threshold outside (0, 1]" do
      expect { described_class.new(max_tokens: 100, threshold: 0.0, keep_recent: 1) }
        .to raise_error(ArgumentError, /threshold must be a Float in/)
      expect { described_class.new(max_tokens: 100, threshold: 1.5, keep_recent: 1) }
        .to raise_error(ArgumentError, /threshold must be a Float in/)
    end

    it "rejects a negative keep_recent" do
      expect { described_class.new(max_tokens: 100, threshold: 0.5, keep_recent: -1) }
        .to raise_error(ArgumentError, /keep_recent must be a non-negative Integer/)
    end

    it "accepts threshold exactly 1.0" do
      expect { described_class.new(max_tokens: 100, threshold: 1.0, keep_recent: 1) }
        .not_to raise_error
    end
  end

  describe "#on_pre_projection" do
    it "is a no-op when estimated tokens are below the threshold" do
      # 4 short messages, each ~5 chars ≈ ~2 tokens → far below trigger
      4.times { |i| append_user_with_text(session, "hi #{i}") }

      Harnas::Hooks.scoped do
        described_class.install(max_tokens: 1000, threshold: 0.5, keep_recent: 2)
        Harnas::Hooks.invoke(:pre_projection, session: session)
      end

      expect(session.log.map(&:type)).not_to include(:compact)
    end

    it "appends a :compact Event when estimated tokens exceed threshold" do
      # Long messages to push token count above threshold
      # 8 messages × 400 chars each = 3200 chars → ~800 tokens
      # Threshold: 1000 * 0.5 = 500 tokens → should trigger
      8.times { |_i| append_user_with_text(session, "x" * 400) }

      Harnas::Hooks.scoped do
        described_class.install(max_tokens: 1000, threshold: 0.5, keep_recent: 2)
        Harnas::Hooks.invoke(:pre_projection, session: session)
      end

      compacts = session.log.select { |e| e.type == :compact }
      expect(compacts.size).to eq(1)
    end

    it "compacts exactly (count - keep_recent) messages" do
      8.times { |_i| append_user_with_text(session, "x" * 400) }

      Harnas::Hooks.scoped do
        described_class.install(max_tokens: 1000, threshold: 0.5, keep_recent: 3)
        Harnas::Hooks.invoke(:pre_projection, session: session)
      end

      compact = session.log.find { |e| e.type == :compact }
      # 8 messages, keep 3 → compact first 5
      expect(compact.payload[:replaces].size).to eq(5)
    end

    it "includes the estimated token count in the summary" do
      8.times { |_i| append_user_with_text(session, "x" * 400) }

      Harnas::Hooks.scoped do
        described_class.install(max_tokens: 1000, threshold: 0.5, keep_recent: 2)
        Harnas::Hooks.invoke(:pre_projection, session: session)
      end

      compact = session.log.find { |e| e.type == :compact }
      expect(compact.payload[:summary]).to match(/compacted \d+ earlier messages/)
      expect(compact.payload[:summary]).to match(/~\d+ tokens/)
    end

    it "does not double-compact on repeated passes below the new threshold" do
      8.times { |_i| append_user_with_text(session, "x" * 400) }

      Harnas::Hooks.scoped do
        described_class.install(max_tokens: 1000, threshold: 0.5, keep_recent: 2)
        Harnas::Hooks.invoke(:pre_projection, session: session)
        Harnas::Hooks.invoke(:pre_projection, session: session)
      end

      # Second pass: only 2 real messages visible (rest are shadowed
      # by the compact) — tokens well below threshold → no new compact.
      expect(session.log.select { |e| e.type == :compact }.size).to eq(1)
    end
  end
end
