# frozen_string_literal: true

require "json"
require "rbconfig"
require "tempfile"
require "harnas/mcp/stdio_client"

RSpec.describe Harnas::MCP::StdioClient do
  def fake_server(script)
    file = Tempfile.new(["harnas-mcp-server", ".rb"])
    file.write(script)
    file.flush
    file.close
    File.chmod(0o755, file.path)
    file
  end

  let(:server_script) do
    <<~RUBY
      #!/usr/bin/env ruby
      require "json"
      $stdout.sync = true
      $stdin.each_line do |line|
        request = JSON.parse(line)
        case request["method"]
        when "initialize"
          puts JSON.generate("jsonrpc" => "2.0", "id" => request["id"], "result" => {})
        when "notifications/initialized"
          next
        when "tools/list"
          puts JSON.generate(
            "jsonrpc" => "2.0",
            "id" => request["id"],
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
          puts JSON.generate(
            "jsonrpc" => "2.0",
            "id" => request["id"],
            "result" => { "content" => [{ "type" => "text", "text" => "stdio body" }] }
          )
        end
      end
    RUBY
  end

  it "performs handshake, lists tools, and calls tools" do
    server = fake_server(server_script)
    client = described_class.new(command: RbConfig.ruby, args: [server.path],
                                 server_name: "editorial-ai")

    expect(client.tools.first["name"]).to eq("editorial-ai.fetch_story")
    expect(client.call_tool("fetch_story", { "uid" => "abc" })).to eq("stdio body")
  ensure
    client&.close
    server&.unlink
  end

  it "raises StartupError when the subprocess cannot spawn" do
    expect do
      described_class.new(command: "/definitely/not/harnas-mcp", server_name: "bad")
    end.to raise_error(Harnas::MCP::StartupError)
  end

  it "raises TransportError when the subprocess exits mid-call" do
    server = fake_server(<<~RUBY)
      #!/usr/bin/env ruby
      require "json"
      $stdout.sync = true
      $stdin.each_line do |line|
        request = JSON.parse(line)
        case request["method"]
        when "initialize"
          puts JSON.generate("jsonrpc" => "2.0", "id" => request["id"], "result" => {})
        when "notifications/initialized"
          next
        when "tools/list"
          exit 0
        end
      end
    RUBY
    client = described_class.new(command: RbConfig.ruby, args: [server.path],
                                 server_name: "bad", timeout: 2)
    client.initialize_session

    expect { client.list_tools }.to raise_error(Harnas::MCP::TransportError)
  ensure
    client&.close
    server&.unlink
  end

  it "raises TimeoutError when a response does not arrive in time" do
    server = fake_server(<<~RUBY)
      #!/usr/bin/env ruby
      require "json"
      $stdout.sync = true
      $stdin.each_line do |line|
        request = JSON.parse(line)
        case request["method"]
        when "initialize"
          puts JSON.generate("jsonrpc" => "2.0", "id" => request["id"], "result" => {})
        when "notifications/initialized"
          next
        when "tools/list"
          sleep 1
        end
      end
    RUBY
    client = described_class.new(command: RbConfig.ruby, args: [server.path],
                                 server_name: "slow", timeout: 2)
    client.initialize_session
    client.instance_variable_set(:@timeout, 0.05)

    expect { client.list_tools }.to raise_error(Harnas::MCP::TimeoutError)
  ensure
    client&.close
    server&.unlink
  end
end
