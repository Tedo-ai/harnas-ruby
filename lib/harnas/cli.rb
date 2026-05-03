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
require "harnas/session"
require "harnas/tools/builtin"

module Harnas
  class CLI
    include SessionCommands
    include Usage

    EXIT_SUCCESS = 0
    EXIT_USAGE = 1
    EXIT_PROVIDER_ERROR = 2

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
        response = agent.stream(input) do |delta|
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

    def run_once
      options = parse_run_options
      raise OptionParser::MissingArgument, "--input" if options[:input].to_s.empty?

      agent = build_agent(options)
      response = agent.chat(options[:input])
      error = terminal_provider_error(agent)
      save_session(agent)
      if error
        @stderr.puts "provider error: #{format_provider_error(error)}"
        return EXIT_PROVIDER_ERROR
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

    def print_help(opts)
      @stdout.puts opts
      exit EXIT_SUCCESS
    end

    def default_options = { provider: nil, model: nil, input: nil }

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
