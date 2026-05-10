# frozen_string_literal: true

require "json"
require "harnas/skills"
require "net/http"
require "open3"
require "pathname"
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
          "harnas.builtin.load_skill" => method(:load_skill)
        }
      end

      # Suggested descriptors for a manifest's tools[] array. Paste
      # these directly; they are not registered until a manifest
      # references them.
      DESCRIPTORS = [
        {
          name: "read_file",
          handler: "harnas.builtin.read_file",
          description: "Read the contents of a file at the given path. " \
                       "Returns the file body as text.",
          input_schema: {
            type: "object",
            properties: { path: { type: "string" } },
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
            properties: { url: { type: "string" } },
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
        }
      ].freeze

      def self.descriptors
        DESCRIPTORS
      end

      # ---- implementations ----

      def self.read_file(args)
        path = require_arg(args, :path)
        File.read(path)
      end

      def self.write_file(args)
        path    = require_arg(args, :path)
        content = require_arg(args, :content)
        File.write(path, content)
        "wrote #{content.bytesize} bytes to #{path}"
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

        response = Net::HTTP.get_response(uri)
        body = response.body.to_s
        body = body.byteslice(0, MAX_FETCH_BYTES) if body.bytesize > MAX_FETCH_BYTES
        "HTTP #{response.code}\n#{body}"
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
