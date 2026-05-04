# frozen_string_literal: true

require "harnas/events/runtime_error"

RSpec.describe Harnas::Events::RuntimeError do
  it "serializes the runtime error payload" do
    event = described_class.new(
      source: :hook,
      handler: "MyHook",
      error_class: "RuntimeError",
      message: "boom",
      terminal: true
    )

    expect(event.to_h).to eq(
      source: "hook",
      handler: "MyHook",
      error_class: "RuntimeError",
      message: "boom",
      terminal: true
    )
  end
end
