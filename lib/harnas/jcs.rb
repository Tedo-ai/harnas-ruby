# frozen_string_literal: true

require "digest"
require "json"

module Harnas
  module JCS
    class InvalidUnicode < StandardError
    end

    module_function

    def canonicalize_json(source, exclude_keys: [])
      validate_surrogate_escapes!(source)
      value = JSON.parse(source)
      Array(exclude_keys).each { |key| value.delete(key) } if value.is_a?(Hash)
      canonicalize(value)
    rescue InvalidUnicode
      raise ArgumentError, "invalid_unicode"
    end

    def content_hash_json(source)
      Digest::SHA256.hexdigest(canonicalize_json(source, exclude_keys: ["content_hash"]))
    end

    def canonicalize(value)
      case value
      when nil
        "null"
      when true
        "true"
      when false
        "false"
      when String
        string(value)
      when Integer
        value.to_s
      when Float
        es6_number(value)
      when Array
        "[#{value.map { |item| canonicalize(item) }.join(",")}]"
      when Hash
        keys = value.keys.sort { |left, right| compare_utf16(left.to_s, right.to_s) }
        "{#{keys.map { |key| "#{string(key.to_s)}:#{canonicalize(value[key])}" }.join(",")}}"
      else
        raise ArgumentError, "unsupported canonical JSON value #{value.class}"
      end
    end

    def string(value)
      out = +"\""
      value.each_codepoint do |codepoint|
        out << case codepoint
               when 0x22 then "\\\""
               when 0x5c then "\\\\"
               when 0x08 then "\\b"
               when 0x09 then "\\t"
               when 0x0a then "\\n"
               when 0x0c then "\\f"
               when 0x0d then "\\r"
               else
                 if codepoint < 0x20
                   format("\\u%04x", codepoint)
                 else
                   codepoint.chr(Encoding::UTF_8)
                 end
               end
      end
      out << "\""
    end

    def es6_number(value)
      raise ArgumentError, "invalid number" unless value.finite?
      return "0" if value.zero?

      raw = value.inspect.sub("E", "e")
      if raw.include?("e")
        mantissa, exponent_text = raw.split("e", 2)
        exponent = exponent_text.to_i
        absolute = value.abs
        return exponent_to_decimal(mantissa, exponent) if absolute >= 1e-6 && absolute < 1e21

        normalize_exponent(mantissa, exponent)
      else
        raw.sub(/\.0\z/, "")
      end
    end

    def exponent_to_decimal(mantissa, exponent)
      negative = mantissa.start_with?("-")
      mantissa = mantissa.delete_prefix("-")
      digits = mantissa.delete(".")
      decimal_places = mantissa.include?(".") ? mantissa.length - mantissa.index(".") - 1 : 0
      point = digits.length - decimal_places + exponent
      out = if point <= 0
              "0.#{"0" * -point}#{digits}"
            elsif point >= digits.length
              "#{digits}#{"0" * (point - digits.length)}"
            else
              "#{digits[0...point]}.#{digits[point..]}"
            end
      out = out.sub(/0+\z/, "").sub(/\.\z/, "")
      negative ? "-#{out}" : out
    end

    def normalize_exponent(mantissa, exponent)
      mantissa = mantissa.sub(/\.0\z/, "")
      sign = exponent.negative? ? "" : "+"
      "#{mantissa}e#{sign}#{exponent}"
    end

    def compare_utf16(left, right)
      left_units = left.encode("UTF-16BE").bytes.each_slice(2).map { |hi, lo| (hi << 8) + lo }
      right_units = right.encode("UTF-16BE").bytes.each_slice(2).map { |hi, lo| (hi << 8) + lo }
      [left_units.length, right_units.length].min.times do |idx|
        comparison = left_units[idx] <=> right_units[idx]
        return comparison unless comparison.zero?
      end
      left_units.length <=> right_units.length
    end

    def validate_surrogate_escapes!(source)
      in_string = false
      i = 0
      while i < source.length
        char = source[i]
        unless in_string
          in_string = true if char == "\""
          i += 1
          next
        end
        if char == "\""
          in_string = false
          i += 1
          next
        end
        if char != "\\"
          i += 1
          next
        end
        i += 1
        next if i >= source.length || source[i] != "u"

        i = advance_unicode_escape!(source, i)
      end
    end

    def advance_unicode_escape!(source, index)
      code = source[(index + 1)...(index + 5)].to_i(16)
      return validate_high_surrogate!(source, index) if code.between?(0xD800, 0xDBFF)

      raise InvalidUnicode if code.between?(0xDC00, 0xDFFF)

      index + 5
    end

    def validate_high_surrogate!(source, index)
      raise InvalidUnicode unless source[(index + 5)...(index + 7)] == "\\u"

      low = source[(index + 7)...(index + 11)].to_i(16)
      raise InvalidUnicode unless low.between?(0xDC00, 0xDFFF)

      index + 11
    end
  end
end
