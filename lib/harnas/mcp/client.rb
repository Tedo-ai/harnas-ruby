# frozen_string_literal: true

require "json"

module Harnas
  # Model Context Protocol adapters.
  module MCP
    PROTOCOL_VERSION = "2024-11-05"
    CLIENT_NAME = "harnas-ruby"
    CLIENT_VERSION = "0.17.0"
    DEFAULT_TIMEOUT = 30

    class Error < StandardError; end
    class TransportError < Error; end
    class StartupError < TransportError; end
    class TimeoutError < TransportError; end

    def self.connect(server_name:, url: nil, command: nil, args: [], env: {},
                     timeout: DEFAULT_TIMEOUT)
      if url
        require "harnas/mcp/http_client"
        return HttpClient.new(url: url, server_name: server_name, timeout: timeout)
      end
      if command
        require "harnas/mcp/stdio_client"
        return StdioClient.new(command: command, args: args, server_name: server_name,
                               env: env, timeout: timeout)
      end

      raise ArgumentError, "either url: or command: is required"
    end

    module ClientBehavior
      attr_reader :server_name, :degraded, :degraded_error

      def tools
        @tools ||= load_tools
      end

      def tool_handlers
        {
          passthrough_handler_name => lambda do |arguments, config: {}|
            call_tool(config.fetch("mcp_tool_name"), arguments)
          end
        }
      end

      def passthrough_handler_name
        "mcp_passthrough.#{server_name}"
      end

      private

      def load_tools
        initialize_session
        list_tools.map do |tool|
          Harnas::MCP::ToolAdapter.from_mcp(
            tool,
            server_name: server_name,
            handler: passthrough_handler_name
          )
        end
      rescue StandardError => e
        @degraded = true
        @degraded_error = e
        warn "Harnas::MCP #{server_name} degraded: #{e.class}: #{e.message}"
        []
      end
    end

    def self.request_payload(id:, method:, params: {})
      payload = { "jsonrpc" => "2.0", "method" => method, "params" => params }
      payload["id"] = id unless id.nil?
      payload
    end

    def self.initialize_params
      {
        "protocolVersion" => PROTOCOL_VERSION,
        "clientInfo" => { "name" => CLIENT_NAME, "version" => CLIENT_VERSION },
        "capabilities" => {}
      }
    end
  end
end
