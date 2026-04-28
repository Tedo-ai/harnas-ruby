#!/usr/bin/env ruby
# frozen_string_literal: true

# Harnas Web: a real-time browser view of a running Harnas agent.
#
# Spins up a Puma server on localhost serving a single-page UI. The
# page connects via WebSocket; every Harnas::Observation event the
# runtime emits is broadcast as JSON to all connected clients. User
# messages typed into the page travel back over the same socket and
# drive a Harnas::AgentLoop turn in a background worker thread.
#
# Usage:
#   bundle exec bin/web.rb [--port PORT] [--mock] [--no-stream]
#
#   --port PORT     listen on PORT (default: 4567)
#   --mock          use a deterministic CannedProvider instead of Anthropic
#   --no-stream     use the buffered Anthropic provider, not streaming

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "optparse"
require "json"
require "rack"
require "rackup"
require "puma"
require "puma/configuration"
require "puma/launcher"
require "puma/events"
require "faye/websocket"
require "eventmachine"
require "dotenv/load"

require "harnas/config"
require "harnas/session"
require "harnas/agent_loop"
require "harnas/events/user_message"
require "harnas/events/assistant_message"
require "harnas/events/assistant_turn_started"
require "harnas/events/assistant_text_delta"
require "harnas/events/assistant_turn_completed"
require "securerandom"
require "harnas/projections/anthropic"
require "harnas/providers/anthropic"
require "harnas/providers/anthropic_stream"
require "harnas/providers/anthropic_stream_live"
require "harnas/providers/openai"
require "harnas/providers/openai_stream"
require "harnas/providers/openai_stream_live"
require "harnas/projections/openai"
require "harnas/ingestors/openai"
require "harnas/providers/gemini"
require "harnas/providers/gemini_stream"
require "harnas/providers/gemini_stream_live"
require "harnas/projections/gemini"
require "harnas/ingestors/gemini"
require "harnas/ingestors/anthropic"
require "harnas/benchmark/canned_provider"
require "harnas/tools/tool"
require "harnas/tools/registry"
require "harnas/tools/runner"
require "harnas/strategies/compaction/marker_tail"
require "harnas/hooks"
require "harnas/observation"

Faye::WebSocket.load_adapter("puma")

options = { port: 4567, mock: false, stream: true, provider: nil }
OptionParser.new do |opts|
  opts.banner = "usage: bin/web.rb [--port PORT] [--provider KIND] [--mock] [--no-stream]"
  opts.on("--port PORT", Integer) { |p| options[:port] = p }
  opts.on("--provider KIND", %w[anthropic openai gemini mock],
          "Starting provider. Unspecified = first available (mock/anthropic/openai/gemini).") do |p|
    options[:provider] = p.to_sym
  end
  opts.on("--mock", "Start on the deterministic mock provider (no API key required)") do
    options[:mock] = true
  end
  opts.on("--no-stream", "Use the buffered provider, not streaming") do
    options[:stream] = false
  end
  opts.on("-h", "--help") do
    puts opts
    exit
  end
end.parse!

# ──────────────────────────────────────────────────────────────────────
# Bridge: a thread-safe broadcaster that fans Observation events out to
# all connected WebSocket clients. Each connection registers itself; the
# bridge holds weak references and prunes closed sockets opportunistically.
# ──────────────────────────────────────────────────────────────────────
class Bridge
  def initialize
    @mutex   = Mutex.new
    @clients = []
  end

  def add(socket)
    @mutex.synchronize { @clients << socket }
  end

  def remove(socket)
    @mutex.synchronize { @clients.delete(socket) }
  end

  def broadcast(message)
    payload = JSON.generate(message)
    snapshot = @mutex.synchronize { @clients.dup }
    snapshot.each do |socket|
      socket.send(payload)
    rescue StandardError
      # Connection died mid-send; drop it on the next prune.
      @mutex.synchronize { @clients.delete(socket) }
    end
  end

  def client_count
    @mutex.synchronize { @clients.size }
  end
end

BRIDGE = Bridge.new

# Subscribe Observation -> Bridge. This subscriber fires synchronously
# from whatever thread emitted the event (typically the AgentLoop worker).
TRACE_DELTAS = !ENV["HARNAS_TRACE_DELTAS"].to_s.empty?

Harnas::Observation.subscribe do |event_name, payload|
  # Opt-in server-side timing trace for streaming deltas. Off by default
  # now that streaming is proven; set HARNAS_TRACE_DELTAS=1 to re-enable.
  if TRACE_DELTAS && event_name == :event_appended
    evt = payload[:event]
    if evt && %i[assistant_text_delta tool_use_argument_delta].include?(evt.type)
      warn "[#{Time.now.strftime("%H:%M:%S.%3N")}] broadcast #{evt.type} seq=#{evt.seq}"
    end
  end

  BRIDGE.broadcast(
    kind: "observation",
    event_name: event_name,
    payload: serialize_for_wire(payload),
    ts: Time.now.to_f
  )
end

# Reduce a payload Hash to JSON-safe primitives. Event objects from the
# Log carry seq/id/type/payload; we surface those directly. Everything
# else is best-effort stringified.
def serialize_for_wire(value)
  case value
  when Harnas::Event then serialize_event(value)
  when Hash          then value.transform_values { |v| serialize_for_wire(v) }
  when Array         then value.map { |v| serialize_for_wire(v) }
  when Symbol        then value.to_s
  when Numeric, String, TrueClass, FalseClass, NilClass then value
  else value.to_s # rubocop:disable Lint/DuplicateBranch -- intentional: above passes-through, this coerces
  end
end

def serialize_event(event)
  {
    seq: event.seq,
    id: event.id,
    type: event.type.to_s,
    payload: serialize_for_wire(event.payload)
  }
end

# ──────────────────────────────────────────────────────────────────────
# Agent setup. One global agent for v0; one Session shared across all
# connected clients. Tab open in two browsers = two views of the same
# session. (Multi-session is a Phase Q concern.)
# ──────────────────────────────────────────────────────────────────────
# Build every provider triplet we have credentials for. Each triplet is
# an { projection, provider_or_stream_provider, ingestor_or_nil, label,
# model } that can be plugged into a per-turn AgentLoop. The Session is
# SHARED across triplets — the Log persists through provider switches
# because Events are provider-neutral.
def build_triplets(stream:)
  out = {}
  out[:mock] = mock_triplet
  out[:anthropic] = anthropic_triplet(stream: stream) if ENV["ANTHROPIC_API_KEY"]
  out[:openai]    = openai_triplet(stream: stream)    if ENV["OPENAI_API_KEY"]
  out[:gemini]    = gemini_triplet(stream: stream)    if ENV["GEMINI_API_KEY"]
  out
end

def pick_initial_provider(options, triplets)
  return :mock if options[:mock]

  wanted = options[:provider]
  return wanted if wanted && triplets.key?(wanted)

  # Default priority: anthropic → openai → gemini → mock
  %i[anthropic openai gemini mock].find { |k| triplets.key?(k) }
end

def build_loop_for(triplet, session, registry)
  runner = Harnas::Tools::Runner.new(registry)
  if triplet[:stream_provider]
    Harnas::AgentLoop.new(
      session: session, projection: triplet[:projection], runner: runner,
      stream_provider: triplet[:stream_provider], max_turns: 6
    )
  else
    Harnas::AgentLoop.new(
      session: session, projection: triplet[:projection], runner: runner,
      provider: triplet[:provider], ingestor: triplet[:ingestor], max_turns: 6
    )
  end
end

# A streaming-shape mock that yields :assistant_text_delta events with a
# small sleep between chunks so the browser visually streams the response
# in. Conforms to the same stream-provider contract as AnthropicStream
# (see spec/15-streaming.md): yields assistant_turn_started, a sequence
# of text deltas, then assistant_turn_completed and the consolidated
# assistant_message.
class FakeStreamProvider # rubocop:disable Style/OneClassPerFile -- script-local helper
  RESPONSE_TEMPLATE = <<~TEXT.strip
    (mock streaming response)

    The Harnas web inspector is connected and showing this response
    chunk by chunk as it arrives. Each block-strip update, each event
    in the right panel, and each character of this text is delivered
    over a single WebSocket bridge from the Ruby runtime to the
    browser. Run with a real ANTHROPIC_API_KEY to see the same wiring
    against an actual model.
  TEXT

  def initialize(chunk_size: 4, delay_ms: 25)
    @chunk_size = chunk_size
    @delay_s    = delay_ms / 1000.0
  end

  def call(_request)
    turn_id = "turn_#{SecureRandom.uuid}"
    yield(type: :assistant_turn_started,
          payload: Harnas::Events::AssistantTurnStarted.new(turn_id: turn_id).to_h)

    text = RESPONSE_TEMPLATE
    text.chars.each_slice(@chunk_size) do |slice|
      chunk = slice.join
      yield(type: :assistant_text_delta,
            payload: Harnas::Events::AssistantTextDelta.new(turn_id: turn_id, chunk: chunk).to_h)
      sleep(@delay_s) if @delay_s.positive?
    end

    yield(type: :assistant_turn_completed,
          payload: Harnas::Events::AssistantTurnCompleted.new(
            turn_id: turn_id, stop_reason: :end_turn,
            usage: { input_tokens: 50, output_tokens: text.length / 4 }
          ).to_h)

    # Consolidated event so Projections see a normal :assistant_message.
    yield(type: :assistant_message,
          payload: Harnas::Events::AssistantMessage.new(
            text: text, stop_reason: :end_turn,
            usage: { input_tokens: 50, output_tokens: text.length / 4 }
          ).to_h)
  end
end

def mock_triplet
  {
    projection: Harnas::Projections::Anthropic.new(model: "mock-model"),
    stream_provider: FakeStreamProvider.new,
    provider: nil,
    ingestor: nil,
    label: "mock (streaming)",
    model: "mock-model"
  }
end

def anthropic_triplet(stream:)
  api_key = ENV.fetch("ANTHROPIC_API_KEY")
  config  = Harnas::Config.for_provider(:anthropic)
  model   = config.fetch(:model)
  {
    projection: Harnas::Projections::Anthropic.new(model: model, registry: SHARED_REGISTRY),
    stream_provider: (if stream
                        Harnas::Providers::AnthropicStreamLive.new(
                          api_key: api_key, api_version: config.fetch(:api_version)
                        )
                      end),
    provider: (if stream
                 nil
               else
                 Harnas::Providers::Anthropic.new(
                   api_key: api_key, api_version: config.fetch(:api_version)
                 )
               end),
    ingestor: (stream ? nil : Harnas::Ingestors::Anthropic.new),
    label: (stream ? "anthropic (streaming)" : "anthropic (buffered)"),
    model: model
  }
end

def openai_triplet(stream:)
  api_key = ENV.fetch("OPENAI_API_KEY")
  config  = Harnas::Config.for_provider(:openai)
  model   = config.fetch(:model)
  {
    projection: Harnas::Projections::OpenAI.new(model: model, registry: SHARED_REGISTRY),
    stream_provider: (stream ? Harnas::Providers::OpenAIStreamLive.new(api_key: api_key) : nil),
    provider: (stream ? nil : Harnas::Providers::OpenAI.new(api_key: api_key)),
    ingestor: (stream ? nil : Harnas::Ingestors::OpenAI.new),
    label: (stream ? "openai (streaming)" : "openai (buffered)"),
    model: model
  }
end

def gemini_triplet(stream:)
  api_key = ENV.fetch("GEMINI_API_KEY")
  config  = Harnas::Config.for_provider(:gemini)
  model   = config.fetch(:model)
  {
    projection: Harnas::Projections::Gemini.new(model: model, registry: SHARED_REGISTRY),
    stream_provider: (stream ? Harnas::Providers::GeminiStreamLive.new(api_key: api_key) : nil),
    provider: (stream ? nil : Harnas::Providers::Gemini.new(api_key: api_key)),
    ingestor: (stream ? nil : Harnas::Ingestors::Gemini.new),
    label: (stream ? "gemini (streaming)" : "gemini (buffered)"),
    model: model
  }
end

# The default registry ships with one tool whose purpose is narrow
# enough that Claude won't volunteer it for generic replies. An `echo`
# tool was removed because its description ("echoes text back") baited
# the model into routing ordinary responses through it — when asked
# "write a long message" Claude picked echo as the natural way to
# produce long output, which made the web inspector look like an agent
# loop pointlessly calling tools on itself.
def build_default_registry
  registry = Harnas::Tools::Registry.new
  registry.register(
    Harnas::Tools::Tool.new(
      name: "get_current_time",
      description: "Returns the current UTC time as an ISO 8601 string. " \
                   "Use this only when the user asks what time it is.",
      input_schema: { type: "object", properties: {}, required: [] }
    ) { |_args| Time.now.utc.iso8601 }
  )
  registry
end

SHARED_REGISTRY = build_default_registry
SHARED_SESSION  = Harnas::Session.create(metadata: { started_on: Time.now.utc.iso8601 })
TRIPLETS        = build_triplets(stream: options[:stream])

raise "no provider credentials found and --mock not requested" if TRIPLETS.empty?

CURRENT_PROVIDER_MUTEX = Mutex.new
@current_provider      = pick_initial_provider(options, TRIPLETS)

def current_provider
  CURRENT_PROVIDER_MUTEX.synchronize { @current_provider }
end

# Snapshot of the live harness configuration, sent to browsers in
# `hello` / `provider_changed` messages so the Configuration panel
# can show what the running agent is actually wired to: provider
# triplet, registered tools, installed strategies (per canonical
# hook point), and max_turns. This is pure introspection — no
# mutation of state.
def current_config_introspection
  kind = current_provider
  triplet = TRIPLETS.fetch(kind)
  {
    provider: {
      kind: kind,
      label: triplet[:label],
      model: triplet[:model],
      projection_class: triplet[:projection].class.name,
      streaming: !triplet[:stream_provider].nil?
    },
    tools: SHARED_REGISTRY.tools.map do |tool|
      { name: tool.name, description: tool.description }
    end,
    hooks: Harnas::Hooks.handlers.each_with_object({}) do |(hook, handlers), h|
      h[hook.to_s] = handlers.size
    end,
    strategies_installed: INSTALLED_STRATEGY_NAMES.dup,
    max_turns: 6
  }
end

def switch_current_provider(kind)
  CURRENT_PROVIDER_MUTEX.synchronize do
    return nil unless TRIPLETS.key?(kind)

    @current_provider = kind
  end
end

# Install the canonical compaction strategy so the live block-strip has
# something interesting to render once the conversation gets long enough.
# Tracked in INSTALLED_STRATEGY_NAMES so the browser's configuration
# panel can display what the running harness is actually wired to.
INSTALLED_STRATEGY_NAMES = [] # rubocop:disable Style/MutableConstant -- populated by install_default_strategies!

def install_default_strategies!
  Harnas::Strategies::Compaction::MarkerTail.install(max_messages: 12, keep_recent: 6)
  INSTALLED_STRATEGY_NAMES << "Compaction::MarkerTail(max_messages=12, keep_recent=6)"
end

install_default_strategies!

# ──────────────────────────────────────────────────────────────────────
# Worker: serializes user messages so that two clicks in quick succession
# don't run two AgentLoop turns concurrently against the same Session.
# The triplet is looked up per turn, so switching providers between
# messages picks up on the next user turn.
# ──────────────────────────────────────────────────────────────────────
WORK_QUEUE = Queue.new

Thread.new do
  loop do
    text = WORK_QUEUE.pop
    next if text.nil? || text.strip.empty?

    kind    = current_provider
    triplet = TRIPLETS.fetch(kind)

    BRIDGE.broadcast(kind: "system", message: "[turn started · #{triplet[:label]}]")
    SHARED_SESSION.log.append(
      type: :user_message,
      payload: Harnas::Events::UserMessage.new(text: text).to_h
    )
    build_loop_for(triplet, SHARED_SESSION, SHARED_REGISTRY).run
    BRIDGE.broadcast(kind: "system", message: "[turn finished]")
  rescue StandardError => e
    BRIDGE.broadcast(kind: "error", message: "#{e.class}: #{e.message}")
  end
end

# ──────────────────────────────────────────────────────────────────────
# Rack app. Three endpoints: GET / serves the page; GET /ws upgrades to
# WebSocket; GET /info returns a tiny JSON about the running agent.
# index.html is re-read on every request so edits show up without a
# server restart, and served with no-store so browsers don't hold a
# stale version across server restarts.
# ──────────────────────────────────────────────────────────────────────
INDEX_HTML_PATH  = File.expand_path("../web/index.html",  __dir__)
AUTHOR_HTML_PATH = File.expand_path("../web/author.html", __dir__)
EXAMPLES_DIR     = File.expand_path("../examples", __dir__)

APP = lambda do |env|
  if Faye::WebSocket.websocket?(env)
    ws = Faye::WebSocket.new(env)

    # Force TCP_NODELAY on the hijacked socket so every WebSocket frame
    # flushes to the network immediately instead of getting batched with
    # subsequent frames by Nagle's algorithm. Puma enables TCP_NODELAY
    # on the listening socket but once the connection is hijacked it's
    # on us to keep it set. Without this, a burst of small delta frames
    # can be coalesced into a single TCP packet and the browser
    # dispatches all onmessage callbacks in one task — producing
    # exactly the 'message flashes in all at once' symptom.
    begin
      io = env["rack.hijack_io"]
      io.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1) if io.respond_to?(:setsockopt)
    rescue StandardError => e
      warn "could not set TCP_NODELAY on hijacked socket: #{e.message}"
    end

    ws.on(:open) do |_event|
      BRIDGE.add(ws)
      kind = current_provider
      t    = TRIPLETS.fetch(kind)
      ws.send(JSON.generate(
                kind: "hello",
                label: t[:label],
                model: t[:model],
                provider: kind,
                providers: TRIPLETS.keys.map { |k| { kind: k, label: TRIPLETS[k][:label] } },
                session: SHARED_SESSION.id,
                config: current_config_introspection,
                log: SHARED_SESSION.log.map { |e| serialize_for_wire(e) }
              ))
    end

    ws.on(:message) do |event|
      data = begin
        JSON.parse(event.data)
      rescue StandardError
        nil
      end
      next unless data.is_a?(Hash)

      case data["kind"]
      when "user_message"
        text = data["text"].to_s
        WORK_QUEUE << text unless text.empty?
      when "set_provider"
        requested = data["provider"].to_s.to_sym
        if switch_current_provider(requested)
          t = TRIPLETS.fetch(requested)
          BRIDGE.broadcast(
            kind: "provider_changed",
            provider: requested,
            label: t[:label],
            model: t[:model],
            config: current_config_introspection
          )
        else
          BRIDGE.broadcast(
            kind: "error",
            message: "provider #{requested.inspect} is not available"
          )
        end
      end
    end

    ws.on(:close) do |_event|
      BRIDGE.remove(ws)
    end

    ws.rack_response
  else
    case env["PATH_INFO"]
    when "/"
      [200,
       { "content-type" => "text/html; charset=utf-8",
         "cache-control" => "no-store, must-revalidate" },
       [File.read(INDEX_HTML_PATH)]]
    when "/author"
      [200,
       { "content-type" => "text/html; charset=utf-8",
         "cache-control" => "no-store, must-revalidate" },
       [File.read(AUTHOR_HTML_PATH)]]
    when %r{\A/examples/([A-Za-z0-9_-]+\.json)\z}
      name = Regexp.last_match(1)
      path = File.join(EXAMPLES_DIR, name)
      if File.exist?(path) && File.dirname(File.expand_path(path)) == EXAMPLES_DIR
        [200,
         { "content-type" => "application/json",
           "cache-control" => "no-store" },
         [File.read(path)]]
      else
        [404, { "content-type" => "text/plain" }, ["not found"]]
      end
    when "/info"
      t = TRIPLETS.fetch(current_provider)
      body = JSON.generate(
        provider: current_provider,
        label: t[:label],
        model: t[:model],
        providers: TRIPLETS.keys,
        session: SHARED_SESSION.id,
        log_size: SHARED_SESSION.log.size,
        clients: BRIDGE.client_count
      )
      [200,
       { "content-type" => "application/json",
         "cache-control" => "no-store" },
       [body]]
    else
      [404, { "content-type" => "text/plain" }, ["not found"]]
    end
  end
end

# ──────────────────────────────────────────────────────────────────────
# Server: Puma in single-mode so the WebSocket upgrade path works
# cleanly (faye-websocket needs Puma's hijack support; the load_adapter
# call above wires it up).
# ──────────────────────────────────────────────────────────────────────
initial = TRIPLETS.fetch(current_provider)
puts ""
puts "  Harnas Web"
puts "  Providers: #{TRIPLETS.keys.join(", ")}"
puts "  Starting:  #{initial[:label]} (#{initial[:model]})"
puts "  Session:   #{SHARED_SESSION.id}"
puts "  URL:       http://localhost:#{options[:port]}/"
puts ""
puts "  Open the URL in a browser. Type messages; switch providers"
puts "  from the header dropdown to use the same Log with a different"
puts "  model on the next turn. Stop with Ctrl-C."
puts ""

config = Puma::Configuration.new do |c|
  c.bind "tcp://0.0.0.0:#{options[:port]}"
  c.app APP
  c.threads 1, 8
  # Don't hang waiting for in-flight WebSocket connections to drain on shutdown.
  c.force_shutdown_after 1
  c.quiet
end

launcher = Puma::Launcher.new(config)

# Puma installs its own SIGINT/SIGTERM handlers inside launcher.run that
# call a graceful stop. Those can hang on hijacked WebSocket connections
# and leave the process alive because our background worker thread is
# not a daemon. Three layers of defense ensure Ctrl-C always exits:
#
# 1. Pre-install a hard-exit trap BEFORE launcher.run so a fast Ctrl-C
#    (within the first ~150ms before Puma overrides the trap) still hits
#    our handler.
# 2. Re-install the trap ~150ms later to replace Puma's graceful stop.
# 3. Wrap launcher.run in begin/ensure { Process.exit!(0) } so any path
#    that leaves launcher.run still terminates the process.
shutting_down = false
hard_exit = lambda do |_signal|
  next if shutting_down

  shutting_down = true
  warn "\nshutting down."
  # Belt + braces: fire a backup force-exit in case something in the
  # current call stack suppresses Process.exit!.
  Thread.new do
    sleep 1
    Process.exit!(0)
  end
  Process.exit!(0)
end

Signal.trap("INT",  &hard_exit)
Signal.trap("TERM", &hard_exit)

Thread.new do
  sleep 0.15
  Signal.trap("INT",  &hard_exit)
  Signal.trap("TERM", &hard_exit)
end

begin
  launcher.run
ensure
  Process.exit!(0)
end
