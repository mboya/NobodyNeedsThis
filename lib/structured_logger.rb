# frozen_string_literal: true

require 'json'
require 'time'

module StructuredLogger
  SENSITIVE_KEYS = %i[
    phone_number account_number callback_url
    authorization api_key
  ].freeze

  module_function

  def log(level:, event:, **fields)
    entry = {
      timestamp: Time.now.utc.iso8601(3),
      level: level,
      event: event,
      service: 'payment-simulator'
    }.merge(sanitize_fields(fields))

    $stdout.puts(entry.to_json)
    $stdout.flush
  end

  def info(event:, **fields)
    log(level: 'info', event: event, **fields)
  end

  def warn(event:, **fields)
    log(level: 'warn', event: event, **fields)
  end

  def error(event:, **fields)
    log(level: 'error', event: event, **fields)
  end

  def sanitize_fields(fields)
    fields.transform_values { |v| sanitize_value(v) }
  end

  def sanitize_value(value)
    case value
    when Hash
      value.transform_keys(&:to_sym).each_with_object({}) do |(key, val), out|
        out[key] = SENSITIVE_KEYS.include?(key) ? redact(key, val) : sanitize_value(val)
      end
    when Array
      value.map { |item| sanitize_value(item) }
    when String
      redact_string(value)
    else
      value
    end
  end

  def redact(key, value)
    return value unless value.is_a?(String)

    redact_string(value, hint: key)
  end

  def redact_string(value, hint: nil)
    return value if value.empty?

    case hint
    when :callback_url
      redact_url(value)
    when :phone_number
      redact_phone(value)
    when :account_number
      redact_account(value)
    else
      redact_by_pattern(value)
    end
  end

  def redact_by_pattern(value)
    return redact_phone(value) if value.match?(/\A254\d{9}\z/)

    return redact_account(value) if value.match?(/\A\d{6,}\z/)

    return redact_url(value) if value.match?(%r{\Ahttps?://}i)

    value
  end

  def redact_phone(value)
    return value if value.length < 7

    "#{value[0..5]}***#{value[-3..]}"
  end

  def redact_account(value)
    return '***' if value.length <= 4

    "***#{value[-4..]}"
  end

  def redact_url(value)
    uri = URI.parse(value)
    host = uri.host.to_s
    redacted_host = host.length > 6 ? "#{host[0..2]}***#{host[-3..]}" : '***'
    "#{uri.scheme}://#{redacted_host}#{uri.path}"
  rescue URI::InvalidURIError
    '[invalid-url]'
  end
end
