# frozen_string_literal: true

require "harnas/tools/tool"

RSpec.describe Harnas::Tools::Tool do
  let(:schema) { { type: "object", properties: { text: { type: "string" } } } }

  def make_tool(&block)
    described_class.new(
      name: "echo",
      description: "returns what you give it",
      input_schema: schema,
      &block || ->(args) { args[:text].to_s }
    )
  end

  it "holds name, description, and input_schema" do
    tool = make_tool
    expect(tool.name).to eq("echo")
    expect(tool.description).to eq("returns what you give it")
    expect(tool.input_schema).to eq(schema)
    expect(tool.args_key_style).to eq(:symbol)
  end

  it "executes the block on #call" do
    tool = make_tool { |args| "hello #{args[:who]}" }
    expect(tool.call(who: "world")).to eq("hello world")
  end

  it "rejects a non-String name" do
    expect do
      described_class.new(name: 1, description: "", input_schema: {}) { |_| "" }
    end.to raise_error(ArgumentError, /name must be a non-empty String/)
  end

  it "rejects an empty name" do
    expect do
      described_class.new(name: "", description: "", input_schema: {}) { |_| "" }
    end.to raise_error(ArgumentError, /name must be a non-empty String/)
  end

  it "rejects a non-String description" do
    expect do
      described_class.new(name: "x", description: nil, input_schema: {}) { |_| "" }
    end.to raise_error(ArgumentError, /description must be a String/)
  end

  it "rejects a non-Hash input_schema" do
    expect do
      described_class.new(name: "x", description: "", input_schema: "nope") { |_| "" }
    end.to raise_error(ArgumentError, /input_schema must be a Hash/)
  end

  it "rejects an invalid args_key_style" do
    expect do
      described_class.new(
        name: "x",
        description: "",
        input_schema: {},
        args_key_style: :camel
      ) { |_| "" }
    end.to raise_error(ArgumentError, /args_key_style/)
  end

  it "requires a block" do
    expect do
      described_class.new(name: "x", description: "", input_schema: {})
    end.to raise_error(ArgumentError, /block required/)
  end
end
