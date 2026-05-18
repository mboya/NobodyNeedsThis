# frozen_string_literal: true

module AppConfig
  module_function

  def rack_env
    ENV.fetch('RACK_ENV', 'development')
  end

  def production?
    rack_env == 'production'
  end

  def development?
    !production?
  end

  def api_keys
    @api_keys ||= parse_list(ENV.fetch('API_KEYS', ENV.fetch('API_KEY', '')))
  end

  def admin_api_key
    ENV['ADMIN_API_KEY'].to_s.strip
  end

  def auth_required?
    return true if production?

    api_keys.any?
  end

  def auth_configured?
    api_keys.any?
  end

  def admin_configured?
    admin_api_key != ''
  end

  def allowed_origins
    @allowed_origins ||= parse_list(ENV.fetch('ALLOWED_ORIGINS', ''))
  end

  def cors_enabled?
    allowed_origins.any?
  end

  def success_rate
    ENV.fetch('SUCCESS_RATE', '0.95').to_f
  end

  def rate_limit_max
    ENV.fetch('RATE_LIMIT_MAX', '60').to_i
  end

  def rate_limit_webhook_max
    ENV.fetch('RATE_LIMIT_WEBHOOK_MAX', '20').to_i
  end

  def rate_limit_window_seconds
    ENV.fetch('RATE_LIMIT_WINDOW', '60').to_i
  end

  def vercel?
    ENV['VERCEL'] == '1'
  end

  def enforce_https?
    return false if vercel? # Vercel terminates TLS at the edge

    production? && ENV.fetch('ENFORCE_HTTPS', 'true') == 'true'
  end

  def debug_endpoints_enabled?
    return true if development? && ENV.fetch('ENABLE_DEBUG_ENDPOINTS', 'true') == 'true'

    admin_configured?
  end

  def reset_enabled?
    return true if development? && ENV.fetch('ENABLE_RESET_ENDPOINT', 'true') == 'true'

    admin_configured?
  end

  def parse_list(value)
    value.split(',').map(&:strip).reject(&:empty?)
  end
  private_class_method :parse_list
end
