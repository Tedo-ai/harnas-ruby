# frozen_string_literal: true

require "base64"

module Harnas
  module InputFile
    def self.content_blocks(text, paths)
      [{ type: "text", text: text }] + paths.map { |path| content_block(path) }
    end

    def self.content_block(path)
      media_type, block_type = media_type_for(path)
      {
        type: block_type,
        media_type: media_type,
        name: File.basename(path),
        source: {
          kind: "base64",
          data: Base64.strict_encode64(File.binread(path))
        }
      }
    end

    def self.media_type_for(path)
      case File.extname(path).downcase
      when ".jpg", ".jpeg" then ["image/jpeg", "image"]
      when ".png"          then ["image/png", "image"]
      when ".gif"          then ["image/gif", "image"]
      when ".webp"         then ["image/webp", "image"]
      when ".pdf"          then ["application/pdf", "document"]
      else
        raise ArgumentError, "unsupported input file type: #{path}"
      end
    end
  end
end
