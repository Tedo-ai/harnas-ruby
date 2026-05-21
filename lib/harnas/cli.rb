# frozen_string_literal: true

require "fileutils"
require "json"
require "optparse"
require "time"

require "harnas/agent"
require "harnas/cli/inspector"
require "harnas/cli/session_commands"
require "harnas/cli/usage"
require "harnas/config"
require "harnas/input_file"
require "harnas/session"
require "harnas/tools/builtin"

module Harnas
  class CLI # rubocop:disable Metrics/ClassLength
    include SessionCommands
    include Usage

    EXIT_SUCCESS = 0
    EXIT_AGENT_ERROR = 1
    EXIT_USAGE = 2
    EXIT_APPROVAL_REJECTED = 3
    EXIT_SANDBOX_VIOLATION = 4
    EXIT_PROVIDER_ERROR = EXIT_AGENT_ERROR

    def initialize(argv:, stdin: $stdin, stdout: $stdout, stderr: $stderr, env: ENV)
      @argv = argv.dup
      @stdin = stdin
      @stdout = stdout
      @stderr = stderr
      @env = env
    end

    def run
      command = @argv.shift
      case command
      when "chat" then run_chat
      when "diff" then run_diff
      when "fork" then run_fork
      when "inspect" then run_inspect
      when "project" then run_project
      when "run" then run_once
      else
        @stderr.puts global_usage
        EXIT_USAGE
      end
    rescue Harnas::Manifest::Error, Harnas::Config::ConfigError, OptionParser::ParseError,
           ArgumentError => e
      @stderr.puts "error: #{e.message}"
      EXIT_USAGE
    end

    private

    def run_chat
      options = parse_chat_options
      agent = build_agent(options)

      @stdout.puts "harnas chat · agent=#{agent.name}"
      @stdout.puts "type 'exit' or 'quit' to leave, Ctrl-D to finish"
      while (line = prompt_line)
        input = line.strip
        next if input.empty?
        break if %w[exit quit].include?(input.downcase)

        streamed = false
        response = stream_agent(agent, input, options) do |delta|
          streamed = true if delta.type == :assistant_text_delta
          print_delta(delta)
        end
        error = terminal_provider_error(agent)
        if error
          @stderr.puts "provider error: #{format_provider_error(error)}"
        elsif streamed
          @stdout.puts
        else
          @stdout.puts response.text
        end
      end

      save_session(agent)
      EXIT_SUCCESS
    end

    def run_inspect
      options = parse_inspect_options
      session = Harnas::Session.load(options.fetch(:session_path))
      inspector = Inspector.new(session)
      if options[:json]
        @stdout.puts JSON.pretty_generate(inspector.to_h)
      else
        @stdout.print inspector.to_text
      end
      EXIT_SUCCESS
    end

    def run_once # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      options = parse_run_options
      raise OptionParser::MissingArgument, "--input" if options[:input].to_s.empty?

      agent = build_agent(options)
      started = Time.now
      response = chat_agent(agent, options[:input], options)
      error = terminal_provider_error(agent)
      runtime_error = terminal_runtime_error(agent)
      save_session(agent)
      if options[:output_format] == "ndjson"
        write_ndjson(agent, started: started, status: ndjson_status(error, runtime_error))
        return ndjson_exit(error, runtime_error)
      end
      if runtime_error&.payload&.dig(:reason) == "sandbox_violation_limit"
        @stderr.puts "sandbox violation: #{runtime_error.payload[:message]}"
        return EXIT_SANDBOX_VIOLATION
      end
      if error
        @stderr.puts "provider error: #{format_provider_error(error)}"
        flush_assistant_messages(agent)
        return EXIT_PROVIDER_ERROR
      end
      if runtime_error
        @stderr.puts "runtime error: #{runtime_error.payload[:message]}"
        flush_assistant_messages(agent)
        return EXIT_AGENT_ERROR
      end

      @stdout.puts response.text
      EXIT_SUCCESS
    end

    def prompt_line
      @stdout.print "> "
      @stdin.gets
    end

    def parse_chat_options
      options = default_options
      parser = OptionParser.new do |opts|
        opts.banner = "usage: harnas chat <manifest> [--provider KIND] [--model MODEL]"
        input_file_option(opts, options)
        provider_model_options(opts, options)
        opts.on("-h", "--help") { print_help(opts) }
      end
      parser.parse!(@argv)
      options.merge(manifest_path: @argv.shift || raise(OptionParser::MissingArgument, "manifest"))
    end

    def parse_inspect_options
      options = { json: false }
      parser = OptionParser.new do |opts|
        opts.banner = "usage: harnas inspect <session.jsonl> [--json]"
        opts.on("--json", "Print machine-readable inspection JSON") { options[:json] = true }
        opts.on("-h", "--help") { print_help(opts) }
      end
      parser.parse!(@argv)
      options.merge(session_path: @argv.shift || raise(OptionParser::MissingArgument, "session"))
    end

    def parse_run_options
      options = default_options
      parser = OptionParser.new do |opts|
        opts.banner = "usage: harnas run <manifest> --input TEXT [--provider KIND] [--model MODEL]"
        opts.on("--input TEXT", "User input to send as one turn") { |v| options[:input] = v }
        input_file_option(opts, options)
        opts.on("--output-format FORMAT", "text (default) or ndjson") do |v|
          options[:output_format] = v
        end
        provider_model_options(opts, options)
        opts.on("-h", "--help") { print_help(opts) }
      end
      parser.parse!(@argv)
      options.merge(manifest_path: @argv.shift || raise(OptionParser::MissingArgument, "manifest"))
    end

    def provider_model_options(opts, options)
      opts.on("--provider KIND", "Override manifest provider kind") { |v| options[:provider] = v }
      opts.on("--model MODEL", "Override manifest provider model") { |v| options[:model] = v }
    end

    def input_file_option(opts, options)
      opts.on("--input-file PATH", "Attach an image or PDF file to the user message") do |v|
        options[:input_files] << v
      end
    end

    def print_help(opts)
      @stdout.puts opts
      exit EXIT_SUCCESS
    end

    def default_options
      { provider: nil, model: nil, input: nil, input_files: [], output_format: "text" }
    end

    def input_payload(text, options)
      return { text: text } if options[:input_files].empty?

      { content: Harnas::InputFile.content_blocks(text, options[:input_files]) }
    end

    def chat_agent(agent, text, options)
      return agent.chat(text) if options[:input_files].empty?

      agent.chat_payload(input_payload(text, options))
    end

    def stream_agent(agent, text, options, &)
      return agent.stream(text, &) if options[:input_files].empty?

      agent.stream_payload(input_payload(text, options), &)
    end

    def build_agent(options)
      manifest = load_manifest(options)
      Harnas::Agent.from_manifest(
        manifest,
        api_keys: api_keys,
        tool_handlers: tool_handlers_for(manifest)
      )
    end

    def api_keys
      { anthropic: @env["ANTHROPIC_API_KEY"], openai: @env["OPENAI_API_KEY"],
        gemini: @env["GEMINI_API_KEY"] }
    end

    def load_manifest(options)
      manifest = JSON.parse(File.read(options.fetch(:manifest_path)))
      provider = manifest.fetch("provider")
      if options[:provider]
        provider["kind"] = options[:provider]
        provider["model"] = resolve_model(provider["kind"], options[:model])
      elsif options[:model]
        provider["model"] = options[:model]
      end
      manifest
    end

    def resolve_model(provider, explicit_model)
      explicit_model ||
        @env["#{provider.upcase}_MODEL"] ||
        Harnas::Config.default_model(provider)
    end

    def tool_handlers_for(manifest)
      handlers = manifest.fetch("tools", []).filter_map do |tool|
        tool["handler"] if tool["handler"].to_s.start_with?("harnas.builtin.")
      end
      return {} if handlers.empty?

      Harnas::Tools::Builtin.handlers
    end

    def terminal_provider_error(agent)
      error = agent.log.reverse_each.find do |event|
        event.type == :provider_error && event.payload[:terminal]
      end
      assistant = agent.log.reverse_each.find { |event| event.type == :assistant_message }
      return error if error && (assistant.nil? || error.seq > assistant.seq)

      nil
    end

    def terminal_runtime_error(agent)
      agent.log.reverse_each.find do |event|
        event.type == :runtime_error && event.payload[:terminal]
      end
    end

    def print_delta(delta)
      @stdout.print delta.payload[:chunk] if delta.type == :assistant_text_delta
    end

    def format_provider_error(error_event)
      payload = error_event.payload
      message = payload[:message].to_s
      return message if payload[:status].nil? || message.start_with?("HTTP #{payload[:status]}")

      "HTTP #{payload[:status]} #{message}"
    end

    def save_session(agent)
      path = run_path(agent.name)
      FileUtils.mkdir_p(File.dirname(path))
      agent.session.save(path)
      @stderr.puts "saved: #{path}"
      path
    end

    def flush_assistant_messages(agent)
      messages = agent.log.select { |event| event.type == :assistant_message }
      messages.each_with_index do |event, index|
        @stdout.puts "---" if index.positive?
        @stdout.puts event.payload[:text]
      end
    end

    def write_ndjson(agent, started:, status:) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength
      # rubocop:disable Metrics/BlockLength
      agent.log.each do |event|
        ts = Time.now.utc.iso8601
        case event.type
        when :tool_use
          @stdout.puts JSON.generate(type: "tool_call", tool: event.payload[:name],
                                     input: event.payload[:arguments], ts: ts)
        when :tool_result
          @stdout.puts JSON.generate(
            type: "tool_result",
            status: event.payload[:error] ? "error" : "success",
            message: event.payload[:error] || event.payload[:output],
            ts: ts
          )
        when :assistant_message
          Array(event.payload[:reasoning]).each do |block|
            content = block[:text].to_s
            next if content.empty?

            @stdout.puts JSON.generate(type: "thinking", content: content, ts: ts)
          end
          @stdout.puts JSON.generate(type: "agent_text", content: event.payload[:text], ts: ts) \
            unless event.payload[:text].to_s.empty?
        when :provider_error
          @stdout.puts JSON.generate(type: "provider_error", message: event.payload[:message],
                                     attempt: event.payload[:attempt], ts: ts)
        when :runtime_error
          @stdout.puts JSON.generate(type: "error", reason: event.payload[:reason],
                                     message: event.payload[:message], ts: ts)
        end
      end
      # rubocop:enable Metrics/BlockLength
      usage = agent.log.each_with_object({ input: 0, output: 0 }) do |event, total|
        next unless event.type == :assistant_message

        usage = event.payload[:usage] || {}
        total[:input] += usage[:input_tokens].to_i
        total[:output] += usage[:output_tokens].to_i
      end
      @stdout.puts JSON.generate(type: "done", status: status,
                                 tokens_used: usage,
                                 duration_ms: ((Time.now - started) * 1000).to_i,
                                 ts: Time.now.utc.iso8601)
    end

    def ndjson_status(provider_error, runtime_error)
      if runtime_error&.payload&.dig(:reason) == "sandbox_violation_limit"
        return "sandbox_violation"
      end

      return runtime_error.payload[:reason] if runtime_error
      return "failed" if provider_error

      "completed"
    end

    def ndjson_exit(provider_error, runtime_error)
      if runtime_error&.payload&.dig(:reason) == "sandbox_violation_limit"
        return EXIT_SANDBOX_VIOLATION
      end

      return EXIT_AGENT_ERROR if provider_error || runtime_error

      EXIT_SUCCESS
    end

    def run_path(name)
      stamp = Time.now.utc.strftime("%Y%m%d-%H%M%S")
      File.join(home_dir, ".harnas", "runs", "#{stamp}-#{slug(name)}.jsonl")
    end

    def home_dir
      @env["HOME"] || Dir.home
    end

    def slug(name)
      name.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-+\z/, "")
    end
  end
end
