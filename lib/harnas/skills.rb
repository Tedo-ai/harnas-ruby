# frozen_string_literal: true

module Harnas
  module Skills
    SKILL_NAME_PATTERN = /\A[a-z][a-z0-9_]*\z/
    INDEX_HEADER = "## Skills"
    INDEX_GUARD = "You have access to local skills. The skill index below is " \
                  "enough to answer what skills are available. Do not call " \
                  "`load_skill` just to list skills. Call `load_skill` only " \
                  "when a user request matches a skill and you need its full " \
                  "instructions."

    def self.valid_name?(name)
      name.is_a?(String) && SKILL_NAME_PATTERN.match?(name)
    end

    def self.build_index(skills_dir)
      entries = skill_entries(skills_dir)
      return "" if entries.empty?

      ([INDEX_HEADER, "", INDEX_GUARD, ""] + entries.map { |entry| format_entry(entry) }).join("\n")
    end

    def self.skill_entries(skills_dir)
      entries = Dir.glob(File.join(skills_dir, "*.md"), sort: true).filter_map do |path|
        frontmatter, = parse_skill_file(path)
        name = frontmatter.fetch("name", File.basename(path, ".md"))
        next unless valid_name?(name)
        next unless name == File.basename(path, ".md")

        description = frontmatter.fetch("description", "").to_s
        next if description.empty?

        {
          name: name,
          description: description,
          category: frontmatter["category"],
          triggers: Array(frontmatter["triggers"]).map(&:to_s)
        }
      end
      entries.sort_by { |entry| entry[:name] }
    end

    def self.format_entry(entry)
      line = "- `#{entry.fetch(:name)}`: #{entry.fetch(:description)}"
      category = entry[:category].to_s
      line += " Category: #{category}." unless category.empty?
      triggers = Array(entry[:triggers]).reject(&:empty?)
      line += " Triggers: #{triggers.join(", ")}." unless triggers.empty?
      line
    end

    def self.parse_skill_file(path)
      content = File.read(path)
      return [{}, content] unless content.start_with?("---\n")

      lines = content.lines
      closing = lines[1..].find_index { |line| line.chomp == "---" }
      return [{}, content] unless closing

      close_index = closing + 1
      raw_frontmatter = lines[1...close_index].join
      body = lines[(close_index + 1)..]&.join || ""
      [parse_frontmatter(raw_frontmatter), body]
    end

    def self.parse_frontmatter(raw)
      fields = {}
      current_list_key = nil
      raw.each_line do |line|
        stripped = line.strip
        next if stripped.empty?

        if current_list_key && stripped.start_with?("- ")
          fields[current_list_key] << stripped.delete_prefix("- ").strip
          next
        end

        current_list_key = parse_frontmatter_line(fields, stripped)
      end
      fields
    end

    def self.parse_frontmatter_line(fields, stripped)
      key, value = stripped.split(":", 2)
      return nil unless value

      key = key.strip
      value = value.strip
      return key if parse_empty_list?(fields, key, value)

      fields[key] = if value.start_with?("[") && value.end_with?("]")
                      value[1...-1].split(",").map(&:strip).reject(&:empty?)
                    else
                      value
                    end
      nil
    end

    def self.parse_empty_list?(fields, key, value)
      return false unless value.empty?

      fields[key] = []
      true
    end
  end
end
