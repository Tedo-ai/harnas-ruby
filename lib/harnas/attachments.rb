# frozen_string_literal: true

require "base64"
require "digest"
require "fileutils"

module Harnas
  module Attachments
    AttachmentReference = Data.define(:uri, :media_type, :byte_size, :sha256, :source)

    class FilesystemStore
      def initialize(root:)
        @root = root
      end

      def put(bytes, media_type)
        data = bytes.b
        digest = Attachments.sha256(data)
        FileUtils.mkdir_p(@root)
        File.binwrite(File.join(@root, "#{digest}#{Attachments.extension(media_type)}"), data)
        Attachments.ref(digest, media_type, data.bytesize, digest)
      end

      def get(uri)
        path = path_for(uri)
        [File.binread(path), Attachments.media_type_for_ext(File.extname(path))]
      end

      def delete(uri)
        id = Attachments.attachment_id(uri)
        Dir.glob(File.join(@root, "#{id}.*")).each { |path| FileUtils.rm_f(path) }
      end

      def exists?(uri)
        id = Attachments.attachment_id(uri)
        Dir.glob(File.join(@root, "#{id}.*")).any?
      rescue ArgumentError
        false
      end

      def list_referenced(log)
        Attachments.list_referenced(log)
      end

      private

      def path_for(uri)
        id = Attachments.attachment_id(uri)
        Dir.glob(File.join(@root, "#{id}.*")).first ||
          raise(Errno::ENOENT, uri)
      end
    end

    class MemoryStore
      def initialize
        @items = {}
      end

      def put(bytes, media_type)
        data = bytes.b.dup
        digest = Attachments.sha256(data)
        uri = "attachment://#{digest}"
        @items[uri] = [data, media_type, digest]
        Attachments.ref(digest, media_type, data.bytesize, digest)
      end

      def get(uri)
        item = @items.fetch(uri) { raise Errno::ENOENT, uri }
        [item[0].dup, item[1]]
      end

      def delete(uri)
        @items.delete(uri)
      end

      def exists?(uri)
        @items.key?(uri)
      end

      def list_referenced(log)
        Attachments.list_referenced(log)
      end
    end

    class InlineStore
      def put(bytes, media_type)
        data = bytes.b
        AttachmentReference.new(
          uri: nil,
          media_type: media_type,
          byte_size: data.bytesize,
          sha256: Attachments.sha256(data),
          source: { kind: "base64", data: Base64.strict_encode64(data) }
        )
      end

      def get(_uri)
        raise "InlineStore does not resolve attachment:// refs"
      end

      def delete(_uri); end

      def exists?(_uri)
        false
      end

      def list_referenced(log)
        Attachments.list_referenced(log)
      end
    end

    def self.list_referenced(log)
      seen = {}
      log.each_with_object([]) do |event, refs|
        next unless %i[user_message assistant_message].include?(event.type)

        Array(event.payload[:content] || event.payload["content"]).each do |block|
          append_ref(ref_uri(block), seen, refs)
        end
      end
    end

    def self.ref_uri(block)
      return nil unless block.is_a?(Hash)

      source = block[:source] || block["source"]
      return nil unless source.is_a?(Hash)
      return nil unless (source[:kind] || source["kind"]) == "ref"

      source[:uri] || source["uri"]
    end

    def self.append_ref(uri, seen, refs)
      return if uri.to_s.empty? || seen[uri]

      seen[uri] = true
      refs << uri
    end

    def self.ref(id, media_type, byte_size, digest)
      uri = "attachment://#{id}"
      AttachmentReference.new(
        uri: uri,
        media_type: media_type,
        byte_size: byte_size,
        sha256: digest,
        source: { kind: "ref", uri: uri }
      )
    end

    def self.sha256(data)
      Digest::SHA256.hexdigest(data)
    end

    def self.attachment_id(uri)
      prefix = "attachment://"
      raise ArgumentError, "invalid attachment uri: #{uri}" unless uri.to_s.start_with?(prefix)

      id = uri[prefix.length..]
      raise ArgumentError, "invalid attachment uri: #{uri}" if id.to_s.empty? || id.include?("/")

      id
    end

    def self.extension(media_type)
      {
        "image/jpeg" => ".jpg",
        "image/png" => ".png",
        "image/gif" => ".gif",
        "image/webp" => ".webp",
        "application/pdf" => ".pdf"
      }.fetch(media_type, ".bin")
    end

    def self.media_type_for_ext(ext)
      {
        ".jpg" => "image/jpeg",
        ".jpeg" => "image/jpeg",
        ".png" => "image/png",
        ".gif" => "image/gif",
        ".webp" => "image/webp",
        ".pdf" => "application/pdf"
      }.fetch(ext, "application/octet-stream")
    end
  end
end
