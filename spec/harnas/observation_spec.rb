# frozen_string_literal: true

require "harnas/observation"

RSpec.describe Harnas::Observation do
  before { described_class.reset! }
  after  { described_class.reset! }

  describe ".subscribe" do
    it "accepts a callable" do
      sub = ->(_e, _p) {}
      expect(described_class.subscribe(sub)).to eq(sub)
      expect(described_class.subscribers).to include(sub)
    end

    it "accepts a block" do
      result = described_class.subscribe { |_e, _p| nil }
      expect(described_class.subscribers).to include(result)
    end

    it "raises when given neither callable nor block" do
      expect { described_class.subscribe }
        .to raise_error(ArgumentError, /requires a subscriber or a block/)
    end
  end

  describe ".unsubscribe" do
    it "removes a previously registered subscriber" do
      sub = described_class.subscribe { |_e, _p| nil }
      described_class.unsubscribe(sub)
      expect(described_class.subscribers).not_to include(sub)
    end
  end

  describe ".emit" do
    it "is a no-op when there are no subscribers" do
      expect { described_class.emit(:anything, x: 1) }.not_to raise_error
    end

    it "delivers events to a subscriber callable" do
      received = []
      described_class.subscribe { |e, p| received << [e, p] }
      described_class.emit(:test, foo: 1)
      expect(received).to eq([[:test, { foo: 1 }]])
    end

    it "delivers events to multiple subscribers in registration order" do
      order = []
      described_class.subscribe { |_e, _p| order << :a }
      described_class.subscribe { |_e, _p| order << :b }
      described_class.subscribe { |_e, _p| order << :c }
      described_class.emit(:test)
      expect(order).to eq(%i[a b c])
    end

    it "isolates subscriber errors so other subscribers still receive events" do
      received = []
      described_class.subscribe { |_e, _p| raise "oops" }
      described_class.subscribe { |e, p| received << [e, p] }
      expect { described_class.emit(:test, x: 1) }.not_to raise_error
      expect(received).to eq([[:test, { x: 1 }]])
    end
  end

  describe ".subscribed" do
    it "yields a Collector and unsubscribes after the block" do
      captured = nil
      described_class.subscribed do |c|
        captured = c
        described_class.emit(:test, x: 1)
      end
      expect(captured.events).to eq([[:test, { x: 1 }]])
      expect(described_class.subscribers).to be_empty
    end

    it "unsubscribes even when the block raises" do
      expect do
        described_class.subscribed { |_c| raise "boom" }
      end.to raise_error("boom")
      expect(described_class.subscribers).to be_empty
    end
  end
end

RSpec.describe Harnas::Observation::Collector do
  it "records events in order" do
    c = described_class.new
    c.call(:a, x: 1)
    c.call(:b, y: 2)
    c.call(:a, x: 3)
    expect(c.events).to eq([[:a, { x: 1 }], [:b, { y: 2 }], [:a, { x: 3 }]])
  end

  it "filters by event name with #of" do
    c = described_class.new
    c.call(:a, x: 1)
    c.call(:b, y: 2)
    c.call(:a, x: 3)
    expect(c.of(:a)).to eq([[:a, { x: 1 }], [:a, { x: 3 }]])
  end

  it "counts emissions with #count" do
    c = described_class.new
    c.call(:a, x: 1)
    c.call(:a, x: 2)
    c.call(:b, y: 1)
    expect(c.count(:a)).to eq(2)
    expect(c.count(:b)).to eq(1)
    expect(c.count(:nope)).to eq(0)
  end

  it "resets via #reset!" do
    c = described_class.new
    c.call(:a, x: 1)
    c.reset!
    expect(c.events).to eq([])
  end
end
