# frozen_string_literal: true

source "https://rubygems.org"

gem "json_schemer" # JSON Schema validation at boundaries

group :development, :test do
  gem "debug"
  gem "rspec"
  gem "rubocop"
  gem "ruby-lsp-rspec", require: false # <-- add this
end

gem "dotenv"
gem "httpx"

# Web mode: bin/web.rb runs a Rack/Puma server with a WebSocket
# bridge that streams Observation events to a browser in real time.
gem "faye-websocket"
gem "puma"
gem "rack"
gem "rackup"
