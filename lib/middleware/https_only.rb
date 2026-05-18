# frozen_string_literal: true

module PaymentSimulator
  module Middleware
  class HttpsOnly
    def initialize(app)
      @app = app
    end

    def call(env)
      unless secure_request?(env)
        return [
          403,
          { 'Content-Type' => 'application/json' },
          ['{"success":false,"message":"HTTPS required"}']
        ]
      end

      status, headers, body = @app.call(env)
      headers['Strict-Transport-Security'] ||= 'max-age=31536000; includeSubDomains'
      [status, headers, body]
    end

    private

    def secure_request?(env)
      return true if env['HTTPS'] == 'on'
      return true if env['HTTP_X_FORWARDED_PROTO'] == 'https'

      false
    end
  end
  end
end
