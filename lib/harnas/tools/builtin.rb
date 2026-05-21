# frozen_string_literal: true

require "json"
require "harnas/skills"
require "net/http"
require "open3"
require "pathname"
require "securerandom"
require "uri"

module Harnas
  module Tools
    # Canonical tool implementations that ship with the reference.
    #
    # These are intentionally low-level, direct-access tools — no
    # sandboxing, no path restriction, no URL blocklist. Adopters
    # who need safety layers are expected to compose them as
    # permission strategies (HumanApproval, DenyByName) or wrap the
    # handlers before passing them to `Agent.from_manifest`.
    #
    # Usage from a manifest:
    #
    #   "tools": [
    #     { "name": "read_file",
    #       "handler": "harnas.builtin.read_file",
    #       "description": "...",
    #       "input_schema": { ... } }
    #   ]
    #
    # Usage from the façade:
    #
    #   Harnas::Agent.from_manifest(
    #     path,
    #     tool_handlers: Harnas::Tools::Builtin.handlers
    #   )
    #
    # Callers who want a mix of built-ins and custom tools merge:
    #
    #   tool_handlers: Harnas::Tools::Builtin.handlers.merge(my_handlers)
    module Builtin # rubocop:disable Metrics/ModuleLength
      # Symbolic handler names → callables. Each callable takes a
      # single Hash argument (with symbol keys, per the Runner) and
      # returns a String.
      def self.handlers
        {
          "harnas.builtin.read_file" => method(:read_file),
          "harnas.builtin.write_file" => method(:write_file),
          "harnas.builtin.edit_file" => method(:edit_file),
          "harnas.builtin.list_dir" => method(:list_dir),
          "harnas.builtin.glob" => method(:glob),
          "harnas.builtin.grep" => method(:grep),
          "harnas.builtin.run_shell" => method(:run_shell),
          "harnas.builtin.fetch_url" => method(:fetch_url),
          "harnas.builtin.spawn_agent" => method(:spawn_agent),
          "harnas.builtin.load_skill" => method(:load_skill),
          "harnas.builtin.bash_session" => bash_session_registry.method(:call)
        }
      end

      # Suggested descriptors for a manifest's tools[] array. Paste
      # these directly; they are not registered until a manifest
      # references them.
      DESCRIPTORS = [
        {
          name: "read_file",
          handler: "harnas.builtin.read_file",
          description: "Read a text file with cat -n style line numbers. " \
                       "Supports optional offset and limit.",
          input_schema: {
            type: "object",
            properties: {
              path: { type: "string" },
              offset: {
                type: "integer",
                description: "Start at line N (0-indexed). Default 0."
              },
              limit: {
                type: "integer",
                description: "Read at most N lines. Default 2000."
              }
            },
            required: ["path"]
          }
        },
        {
          name: "write_file",
          handler: "harnas.builtin.write_file",
          description: "Write text content to a file at the given path, " \
                       "overwriting any existing content.",
          input_schema: {
            type: "object",
            properties: {
              path: { type: "string" },
              content: { type: "string" }
            },
            required: %w[path content]
          }
        },
        {
          name: "edit_file",
          handler: "harnas.builtin.edit_file",
          description: "Replace one occurrence of `old_string` with `new_string` " \
                       "in the file at the given path. Pass replace_all: true to " \
                       "replace every occurrence. Fails if old_string is not found " \
                       "or appears more than once when replace_all is false.",
          input_schema: {
            type: "object",
            properties: {
              path: { type: "string" },
              old_string: { type: "string" },
              new_string: { type: "string" },
              replace_all: { type: "boolean" }
            },
            required: %w[path old_string new_string]
          }
        },
        {
          name: "list_dir",
          handler: "harnas.builtin.list_dir",
          description: "List the entries (files and directories) of the " \
                       "directory at the given path.",
          input_schema: {
            type: "object",
            properties: { path: { type: "string" } },
            required: ["path"]
          }
        },
        {
          name: "glob",
          handler: "harnas.builtin.glob",
          description: "Find files matching a glob pattern (e.g. \"**/*.rb\") " \
                       "under the optional `path` root. Returns a newline-separated " \
                       "list of paths, sorted.",
          input_schema: {
            type: "object",
            properties: {
              pattern: { type: "string" },
              path: { type: "string" }
            },
            required: ["pattern"]
          }
        },
        {
          name: "grep",
          handler: "harnas.builtin.grep",
          description: "Search for a regular expression in file contents under the " \
                       "given path (file or directory). Optional `glob` filters files; " \
                       "optional `case_insensitive` toggles the /i flag. Returns " \
                       "path:lineno:content matches, capped at 200.",
          input_schema: {
            type: "object",
            properties: {
              pattern: { type: "string" },
              path: { type: "string" },
              glob: { type: "string" },
              case_insensitive: { type: "boolean" }
            },
            required: %w[pattern path]
          }
        },
        {
          name: "run_shell",
          handler: "harnas.builtin.run_shell",
          description: "Run a shell command and return its stdout, stderr, " \
                       "and exit status.",
          input_schema: {
            type: "object",
            properties: {
              command: { type: "string" },
              timeout_seconds: { type: "integer", minimum: 1 }
            },
            required: ["command"]
          }
        },
        {
          name: "fetch_url",
          handler: "harnas.builtin.fetch_url",
          description: "Fetch a URL via HTTP GET and return the response " \
                       "body as text.",
          input_schema: {
            type: "object",
            properties: {
              url: { type: "string" },
              headers: {
                type: "object",
                additionalProperties: { type: "string" }
              }
            },
            required: ["url"]
          }
        },
        {
          name: "load_skill",
          handler: "harnas.builtin.load_skill",
          description: "Load the body of a named skill from the configured " \
                       "skills directory.",
          input_schema: {
            type: "object",
            properties: { name: { type: "string" } },
            required: ["name"]
          }
        },
        {
          name: "bash_session",
          handler: "harnas.builtin.bash_session",
          description: "Run a command in a persistent bash session. Sessions preserve " \
                       "working directory and environment variables across calls. " \
                       "stdin is /dev/null; interactive programs cannot receive input.",
          input_schema: {
            type: "object",
            properties: {
              session_id: { type: "string" },
              command: { type: "string" },
              action: { type: "string", enum: %w[run status kill] },
              timeout_ms: { type: "integer", minimum: 1 },
              env: {
                type: "object",
                additionalProperties: { type: "string" }
              }
            }
          }
        },
        {
          name: "spawn_agent",
          handler: "harnas.builtin.spawn_agent",
          description: "Create a child agent Session receipt for a delegated task. " \
                       "Products run and join the child according to their supervisor policy.",
          input_schema: {
            type: "object",
            properties: {
              task: { type: "string" },
              label: { type: "string" },
              role: { type: "string" },
              tools_deny: { type: "array", items: { type: "string" } }
            },
            required: ["task"]
          }
        }
      ].freeze

      def self.descriptors
        DESCRIPTORS
      end

      # ---- implementations ----

      def self.read_file(args)
        path = require_arg(args, :path)
        data = File.binread(path)
        first_chunk = data.byteslice(0, 8192).to_s
        if first_chunk.include?("\0")
          raise ArgumentError, "Cannot read binary file '#{path}'. " \
                               "Use bash_session to inspect binary files."
        end

        offset = [fetch_optional_int(args, :offset), 0].max
        limit = fetch_optional_int(args, :limit)
        limit = 2000 unless limit.positive?
        limit = [limit, 10_000].min
        format_numbered_file(data, offset, limit)
      end

      def self.write_file(args)
        path    = require_arg(args, :path)
        content = require_arg(args, :content)
        File.write(path, content)
        "wrote #{content.bytesize} bytes to #{path}"
      end

      def self.spawn_agent(_args)
        raise "spawn_agent is handled by Harnas::Tools::Runner"
      end

      def self.edit_file(args)
        path        = require_arg(args, :path)
        old_string  = fetch_arg(args, :old_string)
        new_string  = fetch_arg(args, :new_string)
        replace_all = args[:replace_all] || args["replace_all"] || false

        raise ArgumentError, "old_string and new_string must differ" \
          if old_string == new_string

        content = File.read(path)
        count   = content.scan(old_string).size
        raise "old_string not found in #{path}" if count.zero?
        if count > 1 && !replace_all
          raise "old_string appears #{count} times in #{path}; " \
                "pass replace_all: true or add surrounding context"
        end

        updated =
          if replace_all
            content.gsub(old_string, new_string)
          else
            content.sub(old_string, new_string)
          end
        File.write(path, updated)
        "edited #{path} (#{count} replacement#{"s" unless count == 1})"
      end

      def self.list_dir(args)
        path = require_arg(args, :path)
        raise ArgumentError, "not a directory: #{path}" unless File.directory?(path)

        Dir.children(path).sort.join("\n")
      end

      def self.glob(args)
        pattern = require_arg(args, :pattern)
        root    = args[:path] || args["path"] || "."
        full    = Pathname.new(pattern).absolute? ? pattern : File.join(root, pattern)
        Dir.glob(full, sort: true).join("\n")
      end

      GREP_MAX_MATCHES = 200

      def self.grep(args)
        pattern = require_arg(args, :pattern)
        path    = require_arg(args, :path)
        regex   = build_grep_regex(pattern, args)
        files   = grep_candidate_files(path, args)

        matches = collect_grep_matches(files, regex)
        format_grep_result(matches)
      end

      DEFAULT_SHELL_TIMEOUT_SECONDS = 30

      def self.run_shell(args)
        command = require_arg(args, :command)
        timeout = args[:timeout_seconds] || args["timeout_seconds"] ||
                  DEFAULT_SHELL_TIMEOUT_SECONDS
        stdout, stderr, status = run_with_timeout(command, timeout)
        format_shell_result(stdout, stderr, status)
      end

      MAX_FETCH_BYTES = 256 * 1024

      def self.fetch_url(args)
        url = require_arg(args, :url)
        uri = URI.parse(url)
        raise ArgumentError, "only http(s) is supported" \
          unless %w[http https].include?(uri.scheme)

        request = Net::HTTP::Get.new(uri)
        fetch_headers(args).each { |key, value| request[key] = value }
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
          http.request(request)
        end
        body = response.body.to_s
        body = body.byteslice(0, MAX_FETCH_BYTES) if body.bytesize > MAX_FETCH_BYTES
        "HTTP #{response.code}\n#{body}"
      end

      def self.fetch_headers(args)
        headers = args[:headers] || args["headers"] || {}
        raise ArgumentError, "headers must be an object" unless headers.is_a?(Hash)

        headers.each_with_object({}) { |(key, value), out| out[key.to_s] = value.to_s }
      end

      def self.load_skill(args, config: {})
        name = require_arg(args, :name)
        raise "invalid skill name: #{name}" unless Harnas::Skills.valid_name?(name)

        skills_dir = config[:skills_dir] || config["skills_dir"]
        raise "missing skills_dir config" if skills_dir.to_s.empty?

        allowed = Dir.glob(File.join(skills_dir, "*.md")).map { |path| File.basename(path, ".md") }
        raise "unknown skill: #{name}" unless allowed.include?(name)

        path = File.join(skills_dir, "#{name}.md")
        strip = config.fetch(:strip_frontmatter, config.fetch("strip_frontmatter", true))
        return File.read(path) unless strip

        _frontmatter, body = Harnas::Skills.parse_skill_file(path)
        body
      end

      DEFAULT_BASH_SESSION_MAX_OUTPUT_BYTES = 64 * 1024
      ANSI_PATTERN = /\e\[[0-9;]*[mGKHF]|\r/
      ENV_NAME_PATTERN = /\A[A-Za-z_][A-Za-z0-9_]*\z/

      def self.bash_session_registry
        @bash_session_registry ||= BashSessionRegistry.new
      end
      private_class_method :bash_session_registry

      class BashSessionRegistry
        def initialize
          @sessions = {}
          @mutex = Mutex.new
        end

        def call(args, config: {})
          action = fetch_optional(args, :action)
          command = fetch_optional(args, :command)
          action = "run" if action.to_s.empty? && !command.to_s.empty?
          action = "status" if action.to_s.empty?
          session_id = fetch_optional(args, :session_id)

          result = dispatch(action, session_id, command, args, config)
          JSON.generate(result)
        end

        def close
          sessions = @mutex.synchronize do
            values = @sessions.values
            @sessions = {}
            values
          end
          sessions.each(&:close)
        end

        private

        def session(id, config, create:)
          @mutex.synchronize do
            return @sessions[id] if id && @sessions[id]
            raise ArgumentError, "unknown bash_session session_id: #{id}" if id && !create
            raise ArgumentError, "missing required argument: session_id" unless create

            id = "sh_#{SecureRandom.hex(8)}" if id.to_s.empty?
            @sessions[id] = BashSession.new(id, config)
          end
        end

        def fetch_optional(args, key)
          args[key] || args[key.to_s]
        end

        def timeout_ms(value)
          value.to_i.positive? ? value.to_i / 1000.0 : nil
        end

        def dispatch(action, session_id, command, args, config)
          case action
          when "run"
            run_action(session_id, command, args, config)
          when "status"
            session(session_id, config, create: false).status
          when "kill"
            session(session_id, config, create: false).kill
          else
            raise ArgumentError, "unknown bash_session action: #{action}"
          end
        end

        def run_action(session_id, command, args, config)
          raise ArgumentError, "missing required argument: command" if command.to_s.empty?

          session(session_id, config, create: true).run(
            command,
            command_env(fetch_optional(args, :env)),
            timeout_ms(fetch_optional(args, :timeout_ms))
          )
        end

        def command_env(value)
          return {} unless value
          raise ArgumentError, "bash_session env must be an object" unless value.is_a?(Hash)

          value.each_with_object({}) do |(key, item), out|
            key = key.to_s
            unless ENV_NAME_PATTERN.match?(key)
              raise ArgumentError, "invalid bash_session env key: #{key}"
            end
            unless item.is_a?(String)
              raise ArgumentError, "bash_session env value for #{key} must be a string"
            end

            out[key] = item
          end
        end
      end

      # rubocop:disable Metrics/ClassLength
      class BashSession
        def initialize(id, config)
          @id = id
          @stdout = RingBuffer.new(max_output_bytes(config))
          @stderr = RingBuffer.new(max_output_bytes(config))
          @mutex = Mutex.new
          @condition = ConditionVariable.new
          @current = nil
          @closed = false
          start_shell(config)
        end

        def run(command, env, timeout)
          current = start_command(command, env)
          return snapshot("killed", nil, nil) unless current
          return snapshot("killed", nil, current) if current[:write_failed]

          wait_for_command(current, timeout)
        end

        def status
          @mutex.synchronize do
            return snapshot("running", nil, @current) if @current
            return snapshot("killed", nil, nil) if @closed

            snapshot("completed", nil, nil)
          end
        end

        def kill
          current = nil
          @mutex.synchronize do
            return snapshot("completed", nil, nil) unless @current

            current = @current
            kill_process_group("TERM")
            @condition.wait(@mutex, 3) unless current_done?(current)
            kill_process_group("KILL") unless current_done?(current)
            @condition.wait(@mutex) until current_done?(current)
            @closed = true
            snapshot("killed", nil, current)
          end
        end

        def close
          @mutex.synchronize do
            @closed = true
            kill_process_group("KILL")
          end
        end

        private

        def max_output_bytes(config)
          configured = config_value(config, :max_output_bytes).to_i
          configured.positive? ? configured : DEFAULT_BASH_SESSION_MAX_OUTPUT_BYTES
        end

        def config_value(config, key)
          config[key] || config[key.to_s]
        end

        def start_shell(config)
          @shell = resolve_shell(config)
          @stdin, stdout, stderr, @wait_thread = Open3.popen3(
            @shell,
            chdir: resolve_cwd(config),
            pgroup: true
          )
          @stdin.sync = true
          @stdout_thread = Thread.new { read_stdout(stdout) }
          @stderr_thread = Thread.new { read_stderr(stderr) }
          @waiter_thread = Thread.new { wait_shell }
        end

        def resolve_shell(config)
          shell = config_value(config, :shell).to_s
          shell = "bash" if shell.empty?
          shell == "bash" && !system("command -v bash >/dev/null 2>&1") ? "sh" : shell
        end

        def resolve_cwd(config)
          cwd = config_value(config, :cwd).to_s
          File.expand_path(cwd.empty? ? "." : cwd)
        end

        def start_command(command, env)
          @mutex.synchronize do
            @condition.wait(@mutex) while @current
            return nil if @closed

            current = new_command
            @current = current
            @stdin.write(framed_command(command_with_env(command, env), current[:token]))
            current
          rescue IOError, Errno::EPIPE
            @current = nil
            current[:write_failed] = true
            current[:stdout_done] = true
            current[:stderr_done] = true
            complete(current)
            current
          end
        end

        def new_command
          {
            token: SecureRandom.hex(8),
            stdout_start: @stdout.offset,
            stderr_start: @stderr.offset,
            stdout_done: false,
            stderr_done: false,
            exit_code: nil
          }
        end

        def framed_command(command, token)
          "\n{ #{command}\n} </dev/null; __harnas_status=$?; " \
            "printf '__HARNAS_ERR_DONE_#{token}\\n' >&2; " \
            "printf '__HARNAS_DONE_#{token}:%s\\n' \"$__harnas_status\"\n"
        end

        def command_with_env(command, env)
          return command if env.empty?

          assignments = env.keys.sort.map do |key|
            "#{key}=#{shell_quote(env.fetch(key))}"
          end
          (["env"] + assignments + [shell_quote(@shell), "-c", shell_quote(command)]).join(" ")
        end

        def shell_quote(value)
          "'#{value.gsub("'", "'\"'\"'")}'"
        end

        def wait_for_command(current, timeout)
          @mutex.synchronize do
            if timeout
              @condition.wait(@mutex, timeout) unless current_done?(current)
              return snapshot("running", nil, current) unless current_done?(current)
            else
              @condition.wait(@mutex) until current_done?(current)
            end
            snapshot("completed", current[:exit_code], current)
          end
        end

        def read_stdout(io)
          io.each_line do |line|
            before, matched = stdout_sentinel(line)
            @stdout.write(strip_ansi(before)) unless before.empty?
            @stdout.write(strip_ansi(line)) unless matched
          end
        end

        def read_stderr(io)
          io.each_line do |line|
            before, matched = stderr_sentinel(line)
            @stderr.write(strip_ansi(before)) unless before.empty?
            @stderr.write(strip_ansi(line)) unless matched
          end
        end

        def stdout_sentinel(line)
          index = line.index("__HARNAS_DONE_")
          return ["", false] unless index

          before = line[0...index]
          token, code = line[index..].strip.delete_prefix("__HARNAS_DONE_").split(":", 2)
          @mutex.synchronize do
            if @current && @current[:token] == token
              @current[:exit_code] = code.to_i
              @current[:stdout_done] = true
              complete_if_ready
            end
          end
          [before, true]
        end

        def stderr_sentinel(line)
          index = line.index("__HARNAS_ERR_DONE_")
          return ["", false] unless index

          before = line[0...index]
          token = line[index..].strip.delete_prefix("__HARNAS_ERR_DONE_")
          @mutex.synchronize do
            if @current && @current[:token] == token
              @current[:stderr_done] = true
              complete_if_ready
            end
          end
          [before, true]
        end

        def complete_if_ready
          complete(@current) if @current && current_done?(@current)
        end

        def complete(current)
          @current = nil if @current.equal?(current)
          @condition.broadcast
        end

        def current_done?(current)
          current && current[:stdout_done] && current[:stderr_done]
        end

        def wait_shell
          status = @wait_thread.value
          @mutex.synchronize do
            @closed = true
            if @current
              @current[:exit_code] ||= status.exitstatus || -1
              @current[:stdout_done] = true
              @current[:stderr_done] = true
              complete(@current)
            end
          end
        end

        def kill_process_group(signal)
          Process.kill(signal, -@wait_thread.pid)
        rescue Errno::ESRCH, Errno::EPERM
          nil
        end

        def snapshot(status, exit_code, current)
          {
            session_id: @id,
            status: status,
            exit_code: exit_code,
            stdout: @stdout.to_s,
            stderr: @stderr.to_s,
            command_stdout: current ? @stdout.from(current[:stdout_start]) : "",
            command_stderr: current ? @stderr.from(current[:stderr_start]) : "",
            truncated: @stdout.truncated? || @stderr.truncated?
          }
        end

        def strip_ansi(value)
          value.gsub(ANSI_PATTERN, "")
        end
      end
      # rubocop:enable Metrics/ClassLength

      class RingBuffer
        attr_reader :max

        def initialize(max)
          @max = max
          @data = +""
          @total = 0
          @truncated = false
          @mutex = Mutex.new
        end

        def write(value)
          @mutex.synchronize do
            @total += value.bytesize
            @data << value
            if @max.positive? && @data.bytesize > @max
              @truncated = true
              @data = @data.byteslice(@data.bytesize - @max, @max)
            end
          end
        end

        def offset
          @mutex.synchronize { @total }
        end

        def from(offset)
          @mutex.synchronize do
            start_offset = @total - @data.bytesize
            offset = start_offset if offset < start_offset
            offset = @total if offset > @total
            @data.byteslice(offset - start_offset, @data.bytesize).to_s
          end
        end

        def truncated?
          @mutex.synchronize { @truncated }
        end

        def to_s
          @mutex.synchronize { @data.dup }
        end
      end

      # ---- helpers ----

      def self.require_arg(args, key)
        value = args[key] || args[key.to_s]
        raise ArgumentError, "missing required argument: #{key}" \
          if value.nil? || (value.respond_to?(:empty?) && value.empty?)

        value
      end
      private_class_method :require_arg

      # Like require_arg, but only rejects nil — empty strings are a
      # legal value (e.g. edit_file's new_string = "" to delete).
      def self.fetch_arg(args, key)
        value = args.key?(key) ? args[key] : args[key.to_s]
        raise ArgumentError, "missing required argument: #{key}" if value.nil?

        value
      end
      private_class_method :fetch_arg

      def self.fetch_optional_int(args, key)
        value = args.key?(key) ? args[key] : args[key.to_s]
        value.to_i
      end
      private_class_method :fetch_optional_int

      def self.format_numbered_file(data, offset, limit)
        return "... [file has 0 total lines; showing 0–0]\n" if data.empty?

        text = data.force_encoding(Encoding::UTF_8)
        lines = text.split("\n", -1)
        lines.pop if text.end_with?("\n")
        total = lines.length
        if offset >= total
          return "... [file has #{total} total lines; offset #{offset} is past EOF]\n"
        end

        finish = [offset + limit, total].min
        out = +""
        lines[offset...finish].each_with_index do |line, index|
          out << format(
            "%<line_no>6d\t%<line>s\n",
            line_no: offset + index + 1,
            line: line
          )
        end
        if total > offset + limit
          out << "... [file has #{total} total lines; showing #{offset}–#{offset + limit}]\n"
        end
        out
      end
      private_class_method :format_numbered_file

      def self.build_grep_regex(pattern, args)
        flags = args[:case_insensitive] || args["case_insensitive"] ? Regexp::IGNORECASE : 0
        Regexp.new(pattern, flags)
      rescue RegexpError => e
        raise ArgumentError, "invalid regex: #{e.message}"
      end
      private_class_method :build_grep_regex

      def self.grep_candidate_files(path, args)
        if File.file?(path)
          [path]
        elsif File.directory?(path)
          glob = args[:glob] || args["glob"] || "**/*"
          Dir.glob(File.join(path, glob)).select { |p| File.file?(p) }.sort
        else
          raise ArgumentError, "path does not exist: #{path}"
        end
      end
      private_class_method :grep_candidate_files

      def self.collect_grep_matches(files, regex)
        matches = []
        files.each do |file|
          scan_file_for_regex(file, regex, matches)
          break if matches.size >= GREP_MAX_MATCHES
        end
        matches
      end
      private_class_method :collect_grep_matches

      def self.scan_file_for_regex(file, regex, matches)
        content = File.read(file, encoding: "UTF-8", invalid: :replace, undef: :replace)
        content.each_line.with_index(1) do |line, lineno|
          next unless line.match?(regex)

          matches << "#{file}:#{lineno}:#{line.chomp}"
          break if matches.size >= GREP_MAX_MATCHES
        end
      rescue StandardError
        # Skip unreadable files (permissions, encoding edge cases).
        nil
      end
      private_class_method :scan_file_for_regex

      def self.format_grep_result(matches)
        return "no matches" if matches.empty?

        if matches.size >= GREP_MAX_MATCHES
          "#{matches.join("\n")}\n... (truncated at #{GREP_MAX_MATCHES} matches)"
        else
          matches.join("\n")
        end
      end
      private_class_method :format_grep_result

      def self.run_with_timeout(command, timeout)
        out_buf = String.new
        err_buf = String.new
        status  = nil

        Open3.popen3(command) do |_stdin, stdout, stderr, wait_thread|
          finished = wait_thread.join(timeout)
          if finished.nil?
            Process.kill("KILL", wait_thread.pid)
            raise "command timed out after #{timeout}s"
          end
          out_buf << stdout.read.to_s
          err_buf << stderr.read.to_s
          status = wait_thread.value
        end

        [out_buf, err_buf, status]
      end
      private_class_method :run_with_timeout

      def self.format_shell_result(stdout, stderr, status)
        exit_code = status.exitstatus
        [
          "[exit #{exit_code}]",
          stdout.empty?  ? nil : "--- stdout ---\n#{stdout}",
          stderr.empty?  ? nil : "--- stderr ---\n#{stderr}"
        ].compact.join("\n")
      end
      private_class_method :format_shell_result
    end
  end
end
