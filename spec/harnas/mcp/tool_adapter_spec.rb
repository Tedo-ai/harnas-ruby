# frozen_string_literal: true

require "harnas/mcp/tool_adapter"

RSpec.describe Harnas::MCP::ToolAdapter do
  it "translates MCP tool descriptors to namespaced Harnas manifest tools" do
    descriptor = described_class.from_mcp(
      {
        "name" => "fetch_story",
        "description" => "Fetch a story",
        "inputSchema" => { "type" => "object" }
      },
      server_name: "editorial-ai",
      handler: "mcp_passthrough.editorial-ai"
    )

    expect(descriptor).to eq(
      "name" => "editorial-ai.fetch_story",
      "description" => "Fetch a story",
      "input_schema" => { "type" => "object" },
      "handler" => "mcp_passthrough.editorial-ai",
      "config" => {
        "mcp_server_name" => "editorial-ai",
        "mcp_tool_name" => "fetch_story"
      }
    )
  end
end
