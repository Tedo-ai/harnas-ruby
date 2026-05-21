# frozen_string_literal: true

module Harnas
  module Projection
    def self.delegation_tree(session_id, runtime:)
      build_tree(session_id, runtime, {})
    end

    def self.open_children(session_id, runtime:)
      session = load_session(session_id, runtime)
      agent_spawns(session).filter_map do |spawn|
        validate_child_link(session, spawn, runtime)
        spawn_id = spawn.payload[:spawn_id]
        spawn_id unless agent_result_for_spawn(session, spawn_id)
      end
    end

    def self.descendant_timeline(session_id, runtime:)
      rows = collect_descendants(session_id, runtime, {}).flat_map do |session|
        session.log.map do |event|
          {
            "session_id" => session.id,
            "seq" => event.seq,
            "id" => event.id,
            "type" => event.type.to_s,
            "payload" => event.payload,
            "timestamp" => event.payload[:timestamp].to_s
          }
        end
      end
      rows.sort_by { |row| [row["timestamp"], row["session_id"], row["seq"]] }
    end

    def self.descendant_usage(session_id, runtime:)
      totals = { "prompt_tokens" => 0, "completion_tokens" => 0, "total_tokens" => 0 }
      collect_descendants(session_id, runtime, {}).each do |session|
        session.log.each do |event|
          next unless %i[assistant_message agent_result].include?(event.type)

          add_usage!(totals, event.payload[:usage] || {})
        end
      end
      totals
    end

    def self.build_tree(session_id, runtime, visiting) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      raise ArgumentError, "delegation cycle detected at #{session_id}" if visiting[session_id]

      visiting[session_id] = true
      session = load_session(session_id, runtime)
      children = agent_spawns(session).map do |spawn|
        validate_child_link(session, spawn, runtime)
        child = build_tree(spawn.payload[:child_session_id], runtime, visiting)
        result = agent_result_for_spawn(session, spawn.payload[:spawn_id])
        status = result&.payload&.dig(:status) ||
                 last_status_for_spawn(session, spawn.payload[:spawn_id])&.payload&.dig(:status) ||
                 "open"
        {
          "spawn_id" => spawn.payload[:spawn_id],
          "child_session_id" => spawn.payload[:child_session_id],
          "task" => spawn.payload[:task],
          "join_policy" => spawn.payload[:join_policy] || "async",
          "metadata" => spawn.payload[:metadata] || {},
          "status" => status,
          "result" => result&.payload&.dig(:result),
          "error" => result&.payload&.dig(:error),
          "children" => child["children"]
        }
      end
      visiting.delete(session_id)
      { "session_id" => session.id, "children" => children }
    end
    private_class_method :build_tree

    def self.collect_descendants(session_id, runtime, visiting)
      raise ArgumentError, "delegation cycle detected at #{session_id}" if visiting[session_id]

      visiting[session_id] = true
      session = load_session(session_id, runtime)
      sessions = [session]
      agent_spawns(session).each do |spawn|
        validate_child_link(session, spawn, runtime)
        sessions.concat(collect_descendants(spawn.payload[:child_session_id], runtime, visiting))
      end
      visiting.delete(session_id)
      sessions
    end
    private_class_method :collect_descendants

    def self.load_session(session_id, runtime)
      return runtime.fetch(session_id) if runtime.is_a?(Hash)
      return runtime.load_session(session_id) if runtime.respond_to?(:load_session)

      raise ArgumentError, "runtime must be a Hash or respond to #load_session"
    end
    private_class_method :load_session

    def self.agent_spawns(session)
      session.log.select { |event| event.type == :agent_spawn }
    end
    private_class_method :agent_spawns

    def self.validate_child_link(parent, spawn, runtime)
      child = load_session(spawn.payload[:child_session_id], runtime)
      return if child.parent_session_id == parent.id && child.spawn_id == spawn.payload[:spawn_id]

      raise ArgumentError,
            "broken delegation link parent=#{parent.id} spawn=#{spawn.payload[:spawn_id]}"
    end
    private_class_method :validate_child_link

    def self.agent_result_for_spawn(session, spawn_id)
      results = session.log.select do |event|
        event.type == :agent_result && event.payload[:spawn_id] == spawn_id
      end
      if results.size > 1
        raise ArgumentError, "multiple agent_result events for spawn_id #{spawn_id}"
      end

      results.first
    end
    private_class_method :agent_result_for_spawn

    def self.last_status_for_spawn(session, spawn_id)
      session.log.reverse_each.find do |event|
        event.type == :agent_status && event.payload[:spawn_id] == spawn_id
      end
    end
    private_class_method :last_status_for_spawn

    def self.add_usage!(totals, usage)
      prompt = (usage[:prompt_tokens] || usage[:input_tokens] || 0).to_i
      completion = (usage[:completion_tokens] || usage[:output_tokens] || 0).to_i
      total = (usage[:total_tokens] || (prompt + completion)).to_i
      totals["prompt_tokens"] += prompt
      totals["completion_tokens"] += completion
      totals["total_tokens"] += total
    end
    private_class_method :add_usage!
  end
end
