# frozen_string_literal: true

require "harnas/agent"
require "harnas/attachments"
require "harnas/manifest"
require "harnas/session"

module Harnas
  # Convenience wrapper for the common downstream path: load a manifest,
  # optionally resume a saved Session, and expose the prepared runtime parts.
  class Runtime
    attr_reader :loaded

    def self.build(manifest:, session_path: nil, resume: false, metadata: {},
                   attachment_store: nil, **)
      attachment_store ||= Attachments::FilesystemStore.new(
        root: default_attachment_root(session_path)
      )
      loaded = Manifest.load(manifest, attachment_store: attachment_store, **)
      session =
        if resume && session_path
          Session.load(session_path)
        else
          loaded.session
        end
      session = session.with(metadata: session.metadata.merge(metadata)) unless metadata.empty?
      new(loaded.with_session(session))
    end

    def initialize(loaded)
      @loaded = loaded
    end

    def session
      loaded.session
    end

    def registry
      loaded.registry
    end

    def runner
      loaded.runner
    end

    def loop(max_turns: AgentLoop::DEFAULT_MAX_TURNS)
      AgentLoop.new(
        session: loaded.session,
        projection: loaded.projection,
        runner: loaded.runner,
        provider: loaded.provider,
        ingestor: loaded.ingestor,
        provider_kind: loaded.provider_kind,
        max_turns: max_turns
      )
    end

    def agent(max_turns: AgentLoop::DEFAULT_MAX_TURNS)
      Agent.new(loaded: loaded, max_turns: max_turns)
    end

    def save(path)
      session.save(path)
    end

    def self.default_attachment_root(session_path)
      if session_path.to_s != ""
        ext = File.extname(session_path)
        base = ext.empty? ? session_path : session_path.delete_suffix(ext)
        return "#{base}.attachments"
      end

      File.join(Dir.home, ".harnas", "runs", "attachments")
    end
  end
end
