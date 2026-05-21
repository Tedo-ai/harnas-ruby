# frozen_string_literal: true

require "base64"
require "net/http"
require "uri"

module Harnas
  module ContentBlocks
    module_function

    def from_payload(payload)
      content = payload[:content] || payload["content"]
      return Array(content).map { |block| symbolize(block) } if content

      text = payload[:text] || payload["text"]
      text.nil? ? [] : [{ type: "text", text: text }]
    end

    def resolve_data(block, store)
      source = symbolize(block[:source] || block["source"] || {})
      media_type = block[:media_type] || block["media_type"]
      case source[:kind]
      when "base64"
        base64_data(source, media_type)
      when "ref"
        ref_data(source, media_type, store)
      when "url"
        url_data(source, media_type)
      else
        raise ArgumentError, "unsupported content source kind: #{source[:kind]}"
      end
    end

    def base64_data(source, media_type)
      data = source[:data].to_s
      { data: data, media_type: media_type, byte_size: Base64.decode64(data).bytesize }
    end

    def ref_data(source, media_type, store)
      uri = source[:uri].to_s
      raise ArgumentError, "attachment store required to resolve #{uri}" unless store

      bytes, resolved_media_type = store.get(uri)
      { data: Base64.strict_encode64(bytes), media_type: media_type || resolved_media_type,
        byte_size: bytes.bytesize, uri: uri }
    end

    def url_data(source, media_type)
      bytes, resolved_media_type = fetch_url(source[:url].to_s)
      { data: Base64.strict_encode64(bytes), media_type: media_type || resolved_media_type,
        byte_size: bytes.bytesize }
    end

    def fetch_url(url)
      raise ArgumentError, "content source url is required" if url.empty?

      uri = URI(url)
      response = Net::HTTP.get_response(uri)
      unless response.is_a?(Net::HTTPSuccess)
        raise ArgumentError, "fetch attachment url #{url}: status #{response.code}"
      end

      [response.body, response["Content-Type"]]
    rescue URI::InvalidURIError => e
      raise ArgumentError, "fetch attachment url #{url}: #{e.message}"
    end

    def symbolize(value)
      return value.transform_keys(&:to_sym) if value.respond_to?(:transform_keys)

      {}
    end
  end
end
