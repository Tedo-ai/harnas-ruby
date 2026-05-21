# frozen_string_literal: true

require "digest"
require "harnas/events/annotation"
require "harnas/observation"

module Harnas
  module Tools
    module Middleware
      # Guards against stale-read writes: if the agent edits or writes a
      # file whose current disk content doesn't match what the agent
      # last *saw* (per the Log), the edit fails (strict mode) or emits
      # an observation (observe-only mode).
      #
      # State lives in the Log, not in a Ruby instance variable. Every
      # observed view of a file — after read_file, after edit_file,
      # after write_file — is appended as an `:annotation` Event with
      # kind `"stale_read_guard.hash"` and data `{path, sha256}`. The
      # guard derives the last-known hash for a path by scanning the
      # Log for the most recent such annotation.
      #
      # This means: when a Session is saved via Session.save and loaded
      # later, a newly-constructed StaleReadGuard bound to the loaded
      # Log sees exactly the same state it had before — no parallel
      # sidecar store to persist.
      #
      # Opt-in, not default. Constructor takes the Session's Log.
      #
      #   guard = Harnas::Tools::Middleware::StaleReadGuard.new(
      #     log: session.log, strict: true, require_read: true
      #   )
      #
      #   tool_handlers = Harnas::Tools::Builtin.handlers.dup
      #   tool_handlers["harnas.builtin.read_file"]  = guard.wrap_read(
      #     tool_handlers["harnas.builtin.read_file"]
      #   )
      #   tool_handlers["harnas.builtin.edit_file"]  = guard.wrap_edit(
      #     tool_handlers["harnas.builtin.edit_file"]
      #   )
      #   tool_handlers["harnas.builtin.write_file"] = guard.wrap_write(
      #     tool_handlers["harnas.builtin.write_file"]
      #   )
      #
      # Configuration:
      #
      #   strict:        true  (default) raises StaleReadError on drift
      #                  false observe-only — emits :stale_read_guard_fired
      #                        but lets the call proceed
      #   require_read:  true  (default) refuses to edit/write a path the
      #                        agent has never read
      #                  false allows first-time writes without a prior read
      class StaleReadGuard
        class StaleReadError < StandardError; end

        ANNOTATION_KIND = "stale_read_guard.hash"

        def initialize(log:, strict: true, require_read: true)
          @log          = log
          @strict       = strict
          @require_read = require_read
        end

        # Wrap a read_file handler. After a successful read, appends an
        # :annotation Event carrying sha256 of the file content on disk.
        def wrap_read(handler)
          outer = self
          lambda do |args|
            result = handler.call(args)
            path = args[:path] || args["path"]
            outer.send(:refresh_from_disk, path) if path && File.exist?(path)
            result
          end
        end

        def wrap_edit(handler)
          wrap_mutating(handler, action: :edit)
        end

        def wrap_write(handler)
          wrap_mutating(handler, action: :write)
        end

        # Last-recorded hash for `path` per the Log, or nil if never seen.
        def last_hash_for(path)
          @log.reverse_each do |event|
            next unless event.type == :annotation
            next unless event.payload[:kind] == ANNOTATION_KIND
            return event.payload[:data][:sha256] if event.payload[:data][:path] == path
          end
          nil
        end

        def known?(path)
          !last_hash_for(path).nil?
        end

        private

        def wrap_mutating(handler, action:)
          outer = self
          lambda do |args|
            path = args[:path] || args["path"]
            outer.send(:check_fresh!, path, action: action) if path
            result = handler.call(args)
            outer.send(:refresh_from_disk, path) if path && File.exist?(path)
            result
          end
        end

        def record_hash(path, sha256)
          @log.append(
            type: :annotation,
            payload: Events::Annotation.new(
              kind: ANNOTATION_KIND,
              data: { path: path, sha256: sha256 }
            ).to_h
          )
        end

        def refresh_from_disk(path)
          record_hash(path, hash_of(File.binread(path)))
        rescue StandardError
          # If the file is unreadable after the mutation, skip recording.
          nil
        end

        def check_fresh!(path, action:)
          previous = last_hash_for(path)

          if previous.nil?
            # No annotation for this path. If the file doesn't exist on
            # disk, this is a creation — there's no prior content for a
            # write to clobber, so no stale-read concern is possible.
            # Let it through. Only treat it as a never_read violation
            # when the file actually exists (we'd be overwriting content
            # we've never seen).
            return unless File.exist?(path)

            handle_never_read(path, action: action) if @require_read
            return
          end

          current = File.exist?(path) ? hash_of(File.binread(path)) : nil
          return if current == previous

          fire(path, action: action, previous: previous, current: current, reason: :drifted)
        end

        def handle_never_read(path, action:)
          fire(path, action: action, previous: nil, current: nil, reason: :never_read)
        end

        def fire(path, action:, previous:, current:, reason:)
          Observation.emit(
            :stale_read_guard_fired,
            path: path, action: action,
            previous_hash: previous, current_hash: current, reason: reason,
            strict: @strict
          )
          return unless @strict

          raise StaleReadError, stale_message(path, action, reason)
        end

        def stale_message(path, action, reason)
          case reason
          when :never_read
            [
              "StaleReadGuard: refuse to #{action} #{path} — file exists on disk",
              "but has not been read in this session. Call read_file(#{path}) first",
              "to capture its current state, then retry the #{action}."
            ].join(" ")
          else
            [
              "StaleReadGuard: refuse to #{action} #{path} — disk content has",
              "changed since the last read in this session. Call read_file(#{path})",
              "again to refresh, then retry the #{action}."
            ].join(" ")
          end
        end

        def hash_of(string)
          Digest::SHA256.hexdigest(string)
        end
      end
    end
  end
end
