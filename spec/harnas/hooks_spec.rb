# frozen_string_literal: true

require "harnas/hooks"
require "harnas/observation"

RSpec.describe Harnas::Hooks do
  before { described_class.reset! }
  after  { described_class.reset! }

  describe ".on" do
    it "accepts a callable" do
      h = ->(**_) { :yes }
      expect(described_class.on(:test, h)).to eq(h)
      expect(described_class.handlers[:test]).to include(h)
    end

    it "accepts a block" do
      result = described_class.on(:test) { |**_| :yes }
      expect(described_class.handlers[:test]).to include(result)
    end

    it "raises when given neither callable nor block" do
      expect { described_class.on(:test) }
        .to raise_error(ArgumentError, /handler or block required/)
    end

    it "accumulates multiple handlers for the same point" do
      described_class.on(:test) { |**_| 1 }
      described_class.on(:test) { |**_| 2 }
      expect(described_class.handlers[:test].size).to eq(2)
    end
  end

  describe ".off" do
    it "removes a previously-registered handler" do
      h = described_class.on(:test) { |**_| :x }
      described_class.off(:test, h)
      expect(described_class.handlers[:test]).to be_empty
    end
  end

  describe ".invoke" do
    it "returns an empty Array when no handlers are registered" do
      expect(described_class.invoke(:nothing_here)).to eq([])
    end

    it "returns an Array of non-nil handler returns in registration order" do
      described_class.on(:test) { |**_| 1 }
      described_class.on(:test) { |**_| 2 }
      described_class.on(:test) { |**_| 3 }
      expect(described_class.invoke(:test)).to eq([1, 2, 3])
    end

    it "filters out nil handler returns" do
      described_class.on(:test) { |**_| 1 }
      described_class.on(:test) { |**_| nil }
      described_class.on(:test) { |**_| 2 }
      expect(described_class.invoke(:test)).to eq([1, 2])
    end

    it "passes keyword payload to each handler" do
      captured = []
      described_class.on(:test) { |**ctx| captured << ctx }
      described_class.invoke(:test, foo: 1, bar: "x")
      expect(captured).to eq([{ foo: 1, bar: "x" }])
    end

    it "isolates a raising handler so other handlers still run" do
      described_class.on(:test) { |**_| raise "oops" }
      described_class.on(:test) { |**_| :after }
      expect(described_class.invoke(:test)).to eq([:after])
    end

    it "emits :hook_handler_failed on Observation when a handler raises" do
      described_class.on(:test) { |**_| raise StandardError, "oops" }
      Harnas::Observation.subscribed do |c|
        described_class.invoke(:test)
        e = c.of(:hook_handler_failed).first[1]
        expect(e[:point]).to eq(:test)
        expect(e[:error]).to be_a(StandardError)
      end
    end
  end

  describe ".scoped" do
    it "snapshots the registry and restores on block exit" do
      described_class.on(:persistent) { |**_| :p }
      described_class.scoped do
        described_class.on(:scoped_only) { |**_| :s }
        expect(described_class.handlers[:scoped_only]).not_to be_empty
      end
      expect(described_class.handlers[:scoped_only]).to be_empty
      expect(described_class.handlers[:persistent]).not_to be_empty
    end

    it "restores even when the block raises" do
      described_class.on(:persistent) { |**_| :p }
      expect do
        described_class.scoped do
          described_class.on(:scoped_only) { |**_| :s }
          raise "boom"
        end
      end.to raise_error("boom")
      expect(described_class.handlers[:scoped_only]).to be_empty
      expect(described_class.handlers[:persistent]).not_to be_empty
    end
  end

  describe "permission-style any-deny-wins composition (illustrative)" do
    it "lets the caller pick any explicit deny from the returns Array" do
      described_class.on(:pre_tool_use) { |**_| { allow: true } }
      described_class.on(:pre_tool_use) { |**_| { allow: false, reason: "policy" } }
      described_class.on(:pre_tool_use) { |**_| { allow: true } }

      decisions = described_class.invoke(:pre_tool_use)
      denied    = decisions.find { |d| d[:allow] == false }
      expect(denied[:reason]).to eq("policy")
    end
  end
end
