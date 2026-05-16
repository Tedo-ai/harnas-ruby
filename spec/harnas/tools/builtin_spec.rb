# frozen_string_literal: true

require "fileutils"
require "tempfile"
require "tmpdir"
require "harnas/tools/builtin"

RSpec.describe Harnas::Tools::Builtin do
  describe ".handlers" do
    it "returns a Hash keyed by symbolic handler name" do
      expect(described_class.handlers.keys).to contain_exactly(
        "harnas.builtin.read_file",
        "harnas.builtin.write_file",
        "harnas.builtin.edit_file",
        "harnas.builtin.list_dir",
        "harnas.builtin.glob",
        "harnas.builtin.grep",
        "harnas.builtin.run_shell",
        "harnas.builtin.fetch_url",
        "harnas.builtin.load_skill",
        "harnas.builtin.bash_session"
      )
    end

    it "each entry is callable with a Hash" do
      described_class.handlers.each_value do |handler|
        expect(handler).to respond_to(:call)
      end
    end
  end

  describe ".descriptors" do
    it "returns one descriptor per handler with matching handler names" do
      handler_names     = described_class.handlers.keys
      descriptor_names  = described_class.descriptors.map { |d| d[:handler] }
      expect(descriptor_names).to match_array(handler_names)
    end

    it "every descriptor carries name, handler, description, and input_schema" do
      described_class.descriptors.each do |d|
        expect(d).to include(:name, :handler, :description, :input_schema)
        expect(d[:input_schema]).to be_a(Hash)
      end
    end
  end

  describe "read_file" do
    it "returns the file contents" do
      Tempfile.create(["harnas-builtin", ".txt"]) do |f|
        f.write("hello")
        f.flush
        expect(described_class.read_file(path: f.path)).to eq("hello")
      end
    end

    it "raises ArgumentError when path is missing" do
      expect { described_class.read_file({}) }
        .to raise_error(ArgumentError, /path/)
    end

    it "raises Errno::ENOENT when the file does not exist" do
      expect { described_class.read_file(path: "/nonexistent/harnas/xyz") }
        .to raise_error(Errno::ENOENT)
    end
  end

  describe "load_skill" do
    it "loads a skill body and strips frontmatter by default" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "git_workflow.md"), <<~MD)
          ---
          name: git_workflow
          description: Git conventions
          ---
          Write crisp PR descriptions.
        MD

        result = described_class.load_skill(
          { name: "git_workflow" },
          config: { skills_dir: dir }
        )

        expect(result).to eq("Write crisp PR descriptions.\n")
      end
    end

    it "rejects invalid skill names" do
      expect do
        described_class.load_skill({ name: "foo-bar" }, config: { skills_dir: "/tmp" })
      end.to raise_error(RuntimeError, /invalid skill name: foo-bar/)
    end
  end

  describe "write_file" do
    it "writes content and reports the byte count" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "out.txt")
        result = described_class.write_file(path: path, content: "hello")
        expect(File.read(path)).to eq("hello")
        expect(result).to include("5 bytes", path)
      end
    end

    it "raises when path or content is missing" do
      expect { described_class.write_file(path: "/tmp/x") }
        .to raise_error(ArgumentError, /content/)
    end
  end

  describe "edit_file" do
    it "replaces a single occurrence and writes the file in place" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "note.txt")
        File.write(path, "alpha\nbravo\ncharlie\n")
        result = described_class.edit_file(
          path: path, old_string: "bravo", new_string: "BRAVO"
        )
        expect(result).to include("1 replacement")
        expect(File.read(path)).to eq("alpha\nBRAVO\ncharlie\n")
      end
    end

    it "replaces every occurrence when replace_all is true" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "repeat.txt")
        File.write(path, "x\nx\nx\n")
        described_class.edit_file(
          path: path, old_string: "x", new_string: "y", replace_all: true
        )
        expect(File.read(path)).to eq("y\ny\ny\n")
      end
    end

    it "raises when old_string does not appear in the file" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "note.txt")
        File.write(path, "alpha\n")
        expect do
          described_class.edit_file(
            path: path, old_string: "nope", new_string: "anything"
          )
        end.to raise_error(/not found/)
      end
    end

    it "raises when old_string appears more than once and replace_all is false" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "dup.txt")
        File.write(path, "x\nx\n")
        expect do
          described_class.edit_file(path: path, old_string: "x", new_string: "y")
        end.to raise_error(/appears 2 times/)
      end
    end

    it "raises when old_string and new_string are identical" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "same.txt")
        File.write(path, "hi")
        expect do
          described_class.edit_file(path: path, old_string: "hi", new_string: "hi")
        end.to raise_error(/must differ/)
      end
    end

    it "accepts an empty new_string (deletion)" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "del.txt")
        File.write(path, "keep me DELETEME ok")
        described_class.edit_file(
          path: path, old_string: "DELETEME ", new_string: ""
        )
        expect(File.read(path)).to eq("keep me ok")
      end
    end
  end

  describe "glob" do
    it "returns matching paths under the given root, sorted" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "a.rb"), "")
        File.write(File.join(dir, "b.rb"), "")
        File.write(File.join(dir, "c.txt"), "")
        result = described_class.glob(pattern: "*.rb", path: dir)
        expect(result.split("\n").sort).to eq(
          [File.join(dir, "a.rb"), File.join(dir, "b.rb")]
        )
      end
    end

    it "supports recursive ** patterns" do
      Dir.mktmpdir do |dir|
        nested = File.join(dir, "nested")
        FileUtils.mkdir_p(nested)
        File.write(File.join(nested, "deep.rb"), "")
        File.write(File.join(dir, "shallow.rb"), "")
        result = described_class.glob(pattern: "**/*.rb", path: dir)
        expect(result.split("\n").size).to eq(2)
      end
    end

    it "accepts an absolute pattern and ignores the root" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "x.rb"), "")
        result = described_class.glob(pattern: File.join(dir, "*.rb"))
        expect(result).to include(File.join(dir, "x.rb"))
      end
    end

    it "returns an empty string when nothing matches" do
      Dir.mktmpdir do |dir|
        expect(described_class.glob(pattern: "*.nothing", path: dir)).to eq("")
      end
    end
  end

  describe "grep" do
    it "returns path:lineno:content for each match" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "a.txt"), "one\nneedle\nthree\n")
        result = described_class.grep(pattern: "needle", path: dir)
        expect(result).to include("a.txt:2:needle")
      end
    end

    it "searches a single file when path is a file" do
      Tempfile.create(["harnas-grep", ".txt"]) do |f|
        f.write("alpha\nbravo\ncharlie\n")
        f.flush
        result = described_class.grep(pattern: "brav", path: f.path)
        expect(result).to include("#{f.path}:2:bravo")
      end
    end

    it "filters files by the glob argument" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "yes.rb"),  "target line\n")
        File.write(File.join(dir, "no.txt"),  "target line\n")
        result = described_class.grep(
          pattern: "target", path: dir, glob: "**/*.rb"
        )
        expect(result).to include("yes.rb")
        expect(result).not_to include("no.txt")
      end
    end

    it "honors case_insensitive" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "a.txt"), "Needle\n")
        result = described_class.grep(
          pattern: "needle", path: dir, case_insensitive: true
        )
        expect(result).to include("Needle")
      end
    end

    it "returns \"no matches\" when nothing matches" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "a.txt"), "hay hay hay\n")
        expect(described_class.grep(pattern: "needle", path: dir))
          .to eq("no matches")
      end
    end

    it "raises on an invalid regex" do
      Dir.mktmpdir do |dir|
        expect { described_class.grep(pattern: "[unclosed", path: dir) }
          .to raise_error(ArgumentError, /invalid regex/)
      end
    end

    it "raises on a missing path" do
      expect { described_class.grep(pattern: "x", path: "/nonexistent/harnas/xyz") }
        .to raise_error(ArgumentError, /does not exist/)
    end
  end

  describe "list_dir" do
    it "returns a newline-separated list of entries, sorted" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "b.txt"), "")
        File.write(File.join(dir, "a.txt"), "")
        expect(described_class.list_dir(path: dir)).to eq("a.txt\nb.txt")
      end
    end

    it "raises when the path is not a directory" do
      Tempfile.create(["harnas-builtin", ".txt"]) do |f|
        expect { described_class.list_dir(path: f.path) }
          .to raise_error(ArgumentError, /not a directory/)
      end
    end
  end

  describe "run_shell" do
    it "returns stdout, stderr, and exit status for a successful command" do
      result = described_class.run_shell(command: "echo hello")
      expect(result).to include("[exit 0]")
      expect(result).to include("hello")
    end

    it "captures a non-zero exit status" do
      result = described_class.run_shell(command: "ruby -e 'exit 7'")
      expect(result).to include("[exit 7]")
    end

    it "raises when the command runs longer than the timeout" do
      expect do
        described_class.run_shell(command: "sleep 5", timeout_seconds: 1)
      end.to raise_error(/timed out/)
    end
  end

  describe "bash_session" do
    it "preserves working directory and environment in a named session" do
      registry = described_class::BashSessionRegistry.new
      Dir.mktmpdir do |dir|
        first = parse_bash_result(
          registry.call(
            { session_id: "s1", command: "export MYVAR=hello && cd /tmp" },
            config: { cwd: dir, max_output_bytes: 4096 }
          )
        )
        expect(first.fetch("status")).to eq("completed")
        expect(first.fetch("exit_code")).to eq(0)

        second = parse_bash_result(
          registry.call(
            { session_id: "s1", command: "echo $MYVAR && pwd" },
            config: { cwd: dir, max_output_bytes: 4096 }
          )
        )
        expect(second.fetch("stdout")).to include("hello\n/tmp\n")
      end
    ensure
      registry&.close
    end

    it "reports command-local output separately from cumulative output" do
      registry = described_class::BashSessionRegistry.new
      Dir.mktmpdir do |dir|
        first = parse_bash_result(
          registry.call(
            { session_id: "s1", command: "printf first" },
            config: { cwd: dir, max_output_bytes: 4096 }
          )
        )
        expect(first.fetch("stdout")).to eq("first")
        expect(first.fetch("command_stdout")).to eq("first")

        second = parse_bash_result(
          registry.call(
            { session_id: "s1", command: "printf second >&2" },
            config: { cwd: dir, max_output_bytes: 4096 }
          )
        )
        expect(second.fetch("stdout")).to eq("first")
        expect(second.fetch("command_stdout")).to eq("")
        expect(second.fetch("stderr")).to eq("second")
        expect(second.fetch("command_stderr")).to eq("second")
      end
    ensure
      registry&.close
    end

    it "returns running on timeout and can kill the session" do
      registry = described_class::BashSessionRegistry.new
      running = parse_bash_result(
        registry.call(
          { session_id: "s1", command: "sleep 5", timeout_ms: 50 },
          config: { cwd: Dir.tmpdir }
        )
      )
      expect(running.fetch("status")).to eq("running")
      expect(running.fetch("exit_code")).to be_nil

      status = parse_bash_result(registry.call({ session_id: "s1", action: "status" }))
      expect(status.fetch("status")).to eq("running")

      killed = parse_bash_result(registry.call({ session_id: "s1", action: "kill" }))
      expect(killed.fetch("status")).to eq("killed")
    ensure
      registry&.close
    end

    it "truncates output and strips ANSI escapes" do
      registry = described_class::BashSessionRegistry.new
      result = parse_bash_result(
        registry.call(
          { session_id: "s1", command: "printf '\\033[31m0123456789\\033[0m'" },
          config: { cwd: Dir.tmpdir, max_output_bytes: 5 }
        )
      )
      expect(result.fetch("truncated")).to eq(true)
      expect(result.fetch("stdout")).to eq("56789")
      expect(result.fetch("stdout")).not_to include("\e")
    ensure
      registry&.close
    end

    it "returns non-zero exits as tool output" do
      registry = described_class::BashSessionRegistry.new
      result = parse_bash_result(
        registry.call({ session_id: "s1", command: "ruby -e 'exit 7'" })
      )
      expect(result.fetch("status")).to eq("completed")
      expect(result.fetch("exit_code")).to eq(7)
    ensure
      registry&.close
    end

    it "raises clearly for unknown sessions" do
      registry = described_class::BashSessionRegistry.new
      expect do
        registry.call({ session_id: "missing", action: "status" })
      end.to raise_error(ArgumentError, /unknown bash_session session_id/)
    ensure
      registry&.close
    end
  end

  describe "fetch_url" do
    it "raises on unsupported schemes" do
      expect { described_class.fetch_url(url: "file:///etc/passwd") }
        .to raise_error(ArgumentError, /http/)
    end

    it "raises on invalid URLs" do
      # URI.parse tolerates many strings; require the scheme check to
      # catch schemes we don't accept. A truly unparseable URL raises
      # URI::InvalidURIError; either outcome is acceptable as "raised".
      expect { described_class.fetch_url(url: "not a url") }.to raise_error(StandardError)
    end
  end

  describe "integration with Manifest.load" do
    it "resolves handler names from Builtin.handlers" do
      require "harnas/manifest"

      manifest = {
        "harnas_version" => "0.1",
        "name" => "builtin-demo",
        "provider" => { "kind" => "mock", "max_tokens" => 512 },
        "tools" => [described_class.descriptors.first.transform_keys(&:to_s)],
        "strategies" => []
      }

      expect do
        Harnas::Manifest.load(manifest, tool_handlers: described_class.handlers)
      end.not_to raise_error
    end
  end
end

def parse_bash_result(value)
  JSON.parse(value)
end
