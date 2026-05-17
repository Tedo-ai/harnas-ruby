# frozen_string_literal: true

require "json"
require "socket"
require "harnas/mcp/http_client"

RSpec.describe Harnas::MCP::HttpClient do
  def with_server(handler)
    server = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new do
      loop do
        socket = server.accept
        request = read_http_request(socket)
        status, body = handler.call(request)
        socket.write(http_response(status, body))
      rescue IOError
        break
      ensure
        socket&.close
      end
    end
    yield "http://127.0.0.1:#{server.addr[1]}/"
  ensure
    server&.close
    thread&.join
  end

  def read_http_request(socket)
    headers = +""
    headers << socket.readpartial(1024) until headers.include?("\r\n\r\n")
    header_text, body = headers.split("\r\n\r\n", 2)
    length = header_text[/content-length:\s*(\d+)/i, 1].to_i
    body ||= +""
    body << socket.read(length - body.bytesize) if body.bytesize < length
    body
  end

  def http_response(status, body)
    reason = status == 200 ? "OK" : "Internal Server Error"
    [
      "HTTP/1.1 #{status} #{reason}",
      "Content-Type: application/json",
      "Content-Length: #{body.bytesize}",
      "Connection: close",
      "",
      body
    ].join("\r\n")
  end

  it "performs handshake, lists tools, and calls tools" do
    with_server(lambda { |request_body|
      body = JSON.parse(request_body)
      response_body =
        case body["method"]
        when "initialize"
          JSON.generate("jsonrpc" => "2.0", "id" => body["id"], "result" => {})
        when "notifications/initialized"
          JSON.generate("jsonrpc" => "2.0", "result" => {})
        when "tools/list"
          JSON.generate(
            "jsonrpc" => "2.0",
            "id" => body["id"],
            "result" => {
              "tools" => [
                {
                  "name" => "fetch_story",
                  "description" => "Fetch a story",
                  "inputSchema" => { "type" => "object" }
                }
              ]
            }
          )
        when "tools/call"
          JSON.generate(
            "jsonrpc" => "2.0",
            "id" => body["id"],
            "result" => { "content" => [{ "type" => "text", "text" => "story body" }] }
          )
        end
      [200, response_body]
    }) do |url|
      client = Harnas::MCP.connect(url: url, server_name: "editorial-ai")

      expect(client.tools.first).to include(
        "name" => "editorial-ai.fetch_story",
        "handler" => "mcp_passthrough.editorial-ai"
      )
      expect(client.call_tool("fetch_story", { "uid" => "abc" })).to eq("story body")
      expect(client.tool_handlers.fetch("mcp_passthrough.editorial-ai")
                   .call({ "uid" => "abc" }, config: { "mcp_tool_name" => "fetch_story" }))
        .to eq("story body")
    end
  end

  it "raises on non-200 responses" do
    with_server(lambda { |_request_body|
      [500, "boom"]
    }) do |url|
      client = described_class.new(url: url, server_name: "bad")

      expect { client.initialize_session }
        .to raise_error(Harnas::MCP::TransportError, /HTTP 500/)
    end
  end

  it "raises on malformed JSON" do
    with_server(lambda { |_request_body|
      [200, "not-json"]
    }) do |url|
      client = described_class.new(url: url, server_name: "bad")

      expect { client.initialize_session }
        .to raise_error(Harnas::MCP::TransportError, /malformed JSON/)
    end
  end

  it "raises on read timeout" do
    with_server(lambda { |_request_body|
      sleep 0.2
      [200, "{}"]
    }) do |url|
      client = described_class.new(url: url, server_name: "slow", timeout: 0.01)

      expect { client.initialize_session }
        .to raise_error(Harnas::MCP::TimeoutError)
    end
  end

  it "degrades tools when startup fails" do
    with_server(lambda { |_request_body|
      [500, "boom"]
    }) do |url|
      client = described_class.new(url: url, server_name: "bad")

      expect(client.tools).to eq([])
      expect(client.degraded).to eq(true)
    end
  end
end
