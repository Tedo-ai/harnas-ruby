# frozen_string_literal: true

require "harnas/tools/registry"
require "harnas/tools/tool"

RSpec.describe Harnas::Tools::Registry do
  let(:registry) { described_class.new }
  let(:echo) do
    Harnas::Tools::Tool.new(
      name: "echo", description: "", input_schema: {}
    ) { |args| args[:text].to_s }
  end

  it "starts empty" do
    expect(registry.size).to eq(0)
    expect(registry.names).to eq([])
    expect(registry.tools).to eq([])
  end

  it "registers a tool and returns it" do
    expect(registry.register(echo)).to be(echo)
    expect(registry.size).to eq(1)
    expect(registry.names).to eq(["echo"])
  end

  it "looks up a registered tool by name" do
    registry.register(echo)
    expect(registry["echo"]).to be(echo)
  end

  it "reports membership with #include?" do
    registry.register(echo)
    expect(registry.include?("echo")).to be(true)
    expect(registry.include?("unknown")).to be(false)
  end

  it "raises DuplicateToolError on re-registration of the same name" do
    registry.register(echo)
    expect { registry.register(echo) }
      .to raise_error(Harnas::Tools::DuplicateToolError, /already registered/)
  end

  it "raises UnknownToolError on missing name" do
    expect { registry["nope"] }
      .to raise_error(Harnas::Tools::UnknownToolError, /no tool registered/)
  end
end
