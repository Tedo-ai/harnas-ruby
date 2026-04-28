# frozen_string_literal: true

require "harnas/actions/allow"

RSpec.describe Harnas::Actions::Allow do
  it "returns an allow decision hash" do
    expect(described_class.call).to eq({ allow: true })
  end

  it "takes no arguments" do
    expect(described_class.method(:call).arity).to eq(0)
  end
end
