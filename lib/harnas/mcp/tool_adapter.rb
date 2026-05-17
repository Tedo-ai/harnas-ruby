# frozen_string_literal: true

module Harnas
  module MCP
    module ToolAdapter
      def self.from_mcp(mcp_tool, server_name:, handler:)
        raw = mcp_tool.transform_keys(&:to_s)
        original_name = raw.fetch("name")
        {
          "name" => "#{server_name}.#{original_name}",
          "description" => raw["description"].to_s,
          "input_schema" => raw["inputSchema"] || {},
          "handler" => handler,
          "config" => {
            "mcp_server_name" => server_name,
            "mcp_tool_name" => original_name
          }
        }
      end
    end
  end
end
