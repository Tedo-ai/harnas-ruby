# frozen_string_literal: true

require "optparse"

require "harnas/cli/session_ops"

module Harnas
  class CLI
    # Command methods for persisted-Session operator tools.
    module SessionCommands
      private

      def run_diff
        options = parse_diff_options
        result = SessionOps.diff(
          left_path: options.fetch(:left_path),
          right_path: options.fetch(:right_path)
        )
        @stdout.print result.fetch(:text)
        result.fetch(:status)
      end

      def run_fork
        options = parse_fork_options
        @stdout.print SessionOps.fork(
          session_path: options.fetch(:session_path),
          at_seq: options.fetch(:at_seq),
          out: options.fetch(:out)
        )
        EXIT_SUCCESS
      end

      def run_project
        options = parse_project_options
        manifest = load_manifest(options)
        @stdout.print SessionOps.project(
          session_path: options.fetch(:session_path),
          manifest: manifest,
          from_seq: options[:from_seq],
          to_seq: options[:to_seq]
        )
        EXIT_SUCCESS
      end

      def parse_diff_options
        parser = OptionParser.new do |opts|
          opts.banner = "usage: harnas diff <a.jsonl> <b.jsonl>"
          opts.on("-h", "--help") { print_help(opts) }
        end
        parser.parse!(@argv)
        {
          left_path: @argv.shift || raise(OptionParser::MissingArgument, "a.jsonl"),
          right_path: @argv.shift || raise(OptionParser::MissingArgument, "b.jsonl")
        }
      end

      def parse_fork_options
        options = {}
        parser = OptionParser.new do |opts|
          opts.banner = "usage: harnas fork <session.jsonl> --at-seq N --out <new.jsonl>"
          opts.on("--at-seq N", Integer, "Fork after Event seq N") { |v| options[:at_seq] = v }
          opts.on("--out PATH", "Write forked Session JSONL to PATH") { |v| options[:out] = v }
          opts.on("-h", "--help") { print_help(opts) }
        end
        parser.parse!(@argv)
        options[:session_path] = @argv.shift || raise(OptionParser::MissingArgument, "session")
        raise OptionParser::MissingArgument, "--at-seq" unless options.key?(:at_seq)
        raise OptionParser::MissingArgument, "--out" if options[:out].to_s.empty?

        options
      end

      def parse_project_options
        options = default_options.merge(from_seq: nil, to_seq: nil)
        parser = OptionParser.new do |opts|
          opts.banner = "usage: harnas project <session.jsonl> --manifest PATH " \
                        "[--from-seq N] [--to-seq M] [--provider KIND] [--model MODEL]"
          opts.on("--manifest PATH", "Manifest whose projection should render the request") do |v|
            options[:manifest_path] = v
          end
          opts.on("--from-seq N", Integer, "Project from Event seq N") do |v|
            options[:from_seq] = v
          end
          opts.on("--to-seq N", Integer, "Project through Event seq N") { |v| options[:to_seq] = v }
          provider_model_options(opts, options)
          opts.on("-h", "--help") { print_help(opts) }
        end
        parser.parse!(@argv)
        options[:session_path] = @argv.shift || raise(OptionParser::MissingArgument, "session")
        raise OptionParser::MissingArgument, "--manifest" if options[:manifest_path].to_s.empty?

        options
      end
    end
  end
end
