# frozen_string_literal: true

require_relative "openai_stream"

module Harnas
  module Providers
    class OllamaStream < OpenAIStream
      DEFAULT_BASE_URL = "http://localhost:11434/v1"

      def initialize(base_url: ENV.fetch("OLLAMA_BASE_URL", DEFAULT_BASE_URL))
        super(api_key: nil, endpoint: chat_endpoint(base_url), authorization: false)
      end

      private

      def chat_endpoint(base_url)
        base = base_url.to_s.delete_suffix("/")
        return "#{base}/chat/completions" if base.end_with?("/v1")

        "#{base}/v1/chat/completions"
      end
    end
  end
end
