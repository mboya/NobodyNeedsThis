# frozen_string_literal: true

require 'securerandom'
require_relative 'app_config'

module Security
  WEBHOOK_PATHS = %w[
    /api/payments/mpesa/stk-push
    /api/payments/mpesa/callback
    /api/payments/bank-transfer
    /api/payments/bank-transfer/complete
  ].freeze

  PUBLIC_PATHS = %w[/ /docs /api/health].freeze

  module_function

  def public_path?(path)
    PUBLIC_PATHS.include?(path)
  end

  def webhook_path?(path)
    WEBHOOK_PATHS.include?(path)
  end

  def extract_api_key(request)
    auth = request.env['HTTP_AUTHORIZATION'].to_s
    if auth.start_with?('Bearer ')
      return auth.delete_prefix('Bearer ').strip
    end

    key = request.env['HTTP_X_API_KEY'].to_s.strip
    key.empty? ? nil : key
  end

  def valid_api_key?(key)
    return false if key.nil? || key.empty?
    return true if valid_admin_key?(key)

    AppConfig.api_keys.any? { |stored| secure_compare(stored, key) }
  end

  def valid_admin_key?(key)
    return false unless AppConfig.admin_configured?
    return false if key.nil? || key.empty?

    secure_compare(AppConfig.admin_api_key, key)
  end

  def secure_compare(a, b)
    return false unless a.bytesize == b.bytesize

    result = 0
    a.bytes.zip(b.bytes) { |x, y| result |= x ^ y }
    result.zero?
  end

  def client_ip(request)
    forwarded = request.env['HTTP_X_FORWARDED_FOR']
    return forwarded.split(',').first.strip if forwarded && !forwarded.empty?

    request.env['HTTP_X_REAL_IP'] || request.ip
  end

  def request_id(request)
    incoming = request.env['HTTP_X_REQUEST_ID'].to_s.strip
    incoming.empty? ? request.env['payment_simulator.request_id'] : incoming
  end
end
