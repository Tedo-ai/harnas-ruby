# frozen_string_literal: true

module Harnas
  class CLI
    # Shared usage text for the manifest-driven CLI.
    module Usage
      private

      def global_usage
        <<~TEXT
          usage:
            harnas chat <manifest> [--provider KIND] [--model MODEL]
            harnas diff <a.jsonl> <b.jsonl>
            harnas fork <session.jsonl> --at-seq N --out <new.jsonl>
            harnas inspect <session.jsonl> [--json]
            harnas project <session.jsonl> --manifest PATH [--from-seq N] [--to-seq M]
            harnas run <manifest> --input TEXT [--provider KIND] [--model MODEL]
        TEXT
      end
    end
  end
end
