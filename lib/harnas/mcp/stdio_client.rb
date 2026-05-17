# frozen_string_literal: true

require "json"
require "open3"
require "harnas/mcp/client"
require "harnas/mcp/content"
require "harnas/mcp/tool_adapter"

module Harnas
  module MCP
    class StdioClient
      include ClientBehavior

      def initialize(command:, server_name:, args: [], env: {}, timeout: DEFAULT_TIMEOUT)
        @command = command
        @args = args
        @env = env
        @server_name = server_name
        @timeout = timeout
        @next_id = 1
        @responses = {}
        @mutex = Mutex.new
        @condition = ConditionVariable.new
        @degraded = false
        spawn!
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

      def close
        return if @closed

        @closed = true
        @stdin.close unless @stdin.closed?
        kill_process_group("TERM")
        @wait_thread.join(3)
        kill_process_group("KILL") if @wait_thread.alive?
      end

      private

      def spawn!
        @stdin, stdout, _stderr, @wait_thread = Open3.popen3(
          @env,
          @command,
          *@args,
          pgroup: true
        )
        @stdin.sync = true
        @reader_thread = Thread.new { read_stdout(stdout) }
      rescue SystemCallError => e
        raise StartupError, e.message
      end

      def request(method, params)
        id = next_id
        write(MCP.request_payload(id: id, method: method, params: params))
        response = wait_for_response(id)
        raise TransportError, response["error"].inspect if response["error"]

        response.fetch("result")
      end

      def notify(method)
        write(MCP.request_payload(id: nil, method: method, params: {}))
      end

      def next_id
        @mutex.synchronize do
          id = @next_id
          @next_id += 1
          id
        end
      end

      def write(payload)
        @stdin.puts(JSON.generate(payload))
      rescue IOError, Errno::EPIPE => e
        raise TransportError, "MCP subprocess is not writable: #{e.message}"
      end

      def wait_for_response(id)
        deadline = Time.now + @timeout
        @mutex.synchronize do
          loop do
            return @responses.delete(id) if @responses.key?(id)
            if @closed
              raise TransportError,
                    (@reader_error || "MCP subprocess exited before response #{id}")
            end

            remaining = deadline - Time.now
            unless remaining.positive?
              raise TimeoutError, "timed out waiting for MCP response #{id}"
            end

            @condition.wait(@mutex, remaining)
          end
        end
      end

      def read_stdout(stdout)
        stdout.each_line do |line|
          parsed = JSON.parse(line)
          id = parsed["id"]
          next if id.nil?

          @mutex.synchronize do
            @responses[id] = parsed
            @condition.broadcast
          end
        rescue JSON::ParserError => e
          fail_reader("malformed JSON response: #{e.message}")
        end
      ensure
        fail_reader("MCP subprocess exited")
      end

      def fail_reader(message)
        @mutex.synchronize do
          @closed = true
          @reader_error ||= message
          @condition.broadcast
        end
      end

      def kill_process_group(signal)
        Process.kill(signal, -@wait_thread.pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end
    end
  end
end
