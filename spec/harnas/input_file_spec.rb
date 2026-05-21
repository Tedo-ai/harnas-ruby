# frozen_string_literal: true

require "harnas/input_file"
require "tmpdir"

RSpec.describe Harnas::InputFile do
  it "builds a content block for a supported file" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "report.pdf")
      File.binwrite(path, "pdf")

      block = described_class.content_block(path)

      expect(block).to include(type: "document", media_type: "application/pdf",
                               name: "report.pdf")
      expect(block.fetch(:source)).to eq(kind: "base64", data: "cGRm")
    end
  end

  it "rejects unsupported files" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "notes.txt")
      File.binwrite(path, "text")

      expect { described_class.content_block(path) }
        .to raise_error(ArgumentError, /unsupported input file type/)
    end
  end
end
