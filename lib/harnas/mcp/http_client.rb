# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require "harnas/mcp/client"
require "harnas/mcp/content"
require "harnas/mcp/tool_adapter"

module Harnas
  module MCP
    class HttpClient
      include ClientBehavior

      def initialize(url:, server_name:, timeout: DEFAULT_TIMEOUT)
        @uri = URI(url)
        @server_name = server_name
        @timeout = timeout
        @next_id = 1
        @degraded = false
      end

      def initialize_session # rubocop:disable Naming/PredicateMethod
        request("initialize", MCP.initialize_params)
        notify("notifications/initialized")
        true
      end

      def list_tools
        result = request("tools/list", {})
        Array(result.fetch("tools", []))
      end

      def call_tool(name, arguments)
        result = request("tools/call", { "name" => name, "arguments" => arguments || {} })
        Content.flatten(result["content"])
      end

      private

      def request(method, params)
        id = next_id
        response = post(MCP.request_payload(id: id, method: method, params: params))
        parse_response(response).fetch("result")
      end

      def notify(method)
        post(MCP.request_payload(id: nil, method: method, params: {}), parse: false)
      end

      def next_id
        id = @next_id
        @next_id += 1
        id
      end

      def post(payload, parse: true)
        request = Net::HTTP::Post.new(@uri)
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(payload)

        http = Net::HTTP.new(@uri.host, @uri.port)
        http.use_ssl = @uri.scheme == "https"
        http.open_timeout = @timeout
        http.read_timeout = @timeout
        response = http.request(request)
        unless response.is_a?(Net::HTTPSuccess)
          raise TransportError, "HTTP #{response.code}: #{response.body}"
        end

        parse ? response.body : nil
      rescue Net::OpenTimeout, Net::ReadTimeout => e
        raise TimeoutError, e.message
      rescue JSON::ParserError => e
        raise TransportError, "malformed JSON response: #{e.message}"
      end

      def parse_response(body)
        parsed = JSON.parse(body)
        raise TransportError, parsed["error"].inspect if parsed["error"]

        parsed
      rescue JSON::ParserError => e
        raise TransportError, "malformed JSON response: #{e.message}"
      end
    end
  end
end
