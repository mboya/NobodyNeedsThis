# frozen_string_literal: true

require 'sinatra'
require 'sinatra/json'
require 'sinatra/cors'
require 'securerandom'
require_relative 'lib/app_config'
require_relative 'lib/structured_logger'
require_relative 'lib/rate_limiter'
require_relative 'lib/security'
require_relative 'payment_simulator'

set :environment, AppConfig.rack_env.to_sym
set :logging, false

configure :production do
  set :raise_errors, false
  set :dump_errors, false
  set :show_exceptions, false
end

if __FILE__ == $PROGRAM_NAME
  set :port, ENV.fetch('PORT', 3000).to_i
  set :bind, '0.0.0.0'
end

# CORS — restrict to configured origins (no wildcard in production)
if AppConfig.cors_enabled?
  set :allow_origin, AppConfig.allowed_origins
  set :allow_credentials, true
elsif AppConfig.development?
  set :allow_origin, [
    'http://localhost:3000',
    'http://127.0.0.1:3000',
    'http://localhost:4567',
    'http://127.0.0.1:4567',
    'http://localhost:4567',
    'http://127.0.0.1:4567'
  ]
end
set :allow_methods, 'GET,POST,OPTIONS'
set :allow_headers, 'content-type,authorization,x-api-key,x-request-id'

$simulator = PaymentSimulator::Simulator.new(success_rate: AppConfig.success_rate)
$general_rate_limiter = RateLimiter.new(
  max_requests: AppConfig.rate_limit_max,
  window_seconds: AppConfig.rate_limit_window_seconds
)
$webhook_rate_limiter = RateLimiter.new(
  max_requests: AppConfig.rate_limit_webhook_max,
  window_seconds: AppConfig.rate_limit_window_seconds
)

def halt_json(status_code, payload)
  halt status_code, payload.to_json
end

def require_api_key!
  return if Security.public_path?(request.path_info)
  return unless AppConfig.auth_required?

  if AppConfig.production? && !AppConfig.auth_configured?
    StructuredLogger.error(event: 'auth.misconfigured')
    halt_json 503, success: false, message: 'API authentication is not configured'
  end

  key = Security.extract_api_key(request)
  return if Security.valid_api_key?(key)

  StructuredLogger.warn(
    event: 'auth.denied',
    path: request.path_info,
    method: request.request_method,
    client_ip: Security.client_ip(request)
  )
  halt_json 401, success: false, message: 'Unauthorized'
end

def require_admin_key!
  key = Security.extract_api_key(request)
  return if Security.valid_admin_key?(key)

  StructuredLogger.warn(
    event: 'admin.denied',
    path: request.path_info,
    method: request.request_method,
    client_ip: Security.client_ip(request)
  )
  halt_json 403, success: false, message: 'Forbidden'
end

def enforce_rate_limit!
  return if Security.public_path?(request.path_info)
  return if request.request_method == 'OPTIONS'

  limiter = Security.webhook_path?(request.path_info) ? $webhook_rate_limiter : $general_rate_limiter
  client_key = "#{Security.client_ip(request)}:#{request.path_info}"

  return if limiter.allow?(client_key)

  retry_after = limiter.retry_after(client_key)
  response.headers['Retry-After'] = retry_after.to_s
  StructuredLogger.warn(
    event: 'rate_limit.exceeded',
    path: request.path_info,
    method: request.request_method,
    client_ip: Security.client_ip(request),
    retry_after: retry_after
  )
  halt_json 429, success: false, message: 'Too many requests', retry_after: retry_after
end

def assign_request_id!
  request.env['payment_simulator.request_id'] ||= SecureRandom.uuid
  response.headers['X-Request-Id'] = request.env['payment_simulator.request_id']
end

def log_request_start
  request.env['payment_simulator.started_at'] = Time.now
  StructuredLogger.info(
    event: 'request.start',
    request_id: Security.request_id(request),
    method: request.request_method,
    path: request.path_info,
    client_ip: Security.client_ip(request)
  )
end

def log_request_finish
  started_at = request.env['payment_simulator.started_at']
  duration_ms = started_at ? ((Time.now - started_at) * 1000).round : nil

  StructuredLogger.info(
    event: 'request.finish',
    request_id: Security.request_id(request),
    method: request.request_method,
    path: request.path_info,
    status: response.status,
    duration_ms: duration_ms
  )
end

def schedule_callback(transaction_id, delay, force_success = nil)
  Thread.new do
    sleep delay
    result = $simulator.simulate_mpesa_callback(transaction_id, force_success: force_success)
    result_code = result.dig(:Body, :stkCallback, :ResultCode)
    txn = $simulator.transactions[transaction_id]

    StructuredLogger.info(
      event: 'callback.mpesa.completed',
      transaction_id: transaction_id,
      result_code: result_code,
      webhook_sent: txn&.dig(:webhook_sent) == true
    )
  rescue StandardError => e
    StructuredLogger.error(
      event: 'callback.mpesa.failed',
      transaction_id: transaction_id,
      error: e.message
    )
  end
end

def schedule_bank_completion(transaction_id, delay, force_success = nil)
  Thread.new do
    sleep delay
    result = $simulator.simulate_bank_transfer_completion(transaction_id, force_success: force_success)
    txn = $simulator.transactions[transaction_id]

    StructuredLogger.info(
      event: 'callback.bank.completed',
      transaction_id: transaction_id,
      status: result[:status],
      webhook_sent: txn&.dig(:webhook_sent) == true
    )
  rescue StandardError => e
    StructuredLogger.error(
      event: 'callback.bank.failed',
      transaction_id: transaction_id,
      error: e.message
    )
  end
end

before do
  assign_request_id!
  enforce_rate_limit!
  require_api_key!
  log_request_start
end

after do
  log_request_finish
end

# Health check (public, no auth)
get '/api/health' do
  json(
    status: 'healthy',
    service: 'payment-simulator',
    environment: AppConfig.rack_env,
    auth_required: AppConfig.auth_required?
  )
end

# Debug — disabled in production unless ADMIN_API_KEY is set
get '/api/debug/threads' do
  halt_json 404, success: false, message: 'Not found' unless AppConfig.debug_endpoints_enabled?
  require_admin_key! if AppConfig.production?

  json(
    thread_count: Thread.list.count,
    threads: Thread.list.map { |t| { status: t.status, alive: t.alive? } }
  )
end

post '/api/payments/mpesa/stk-push' do
  request_body = JSON.parse(request.body.read, symbolize_names: true)

  required_fields = %i[phone_number amount]
  missing_fields = required_fields.reject { |field| request_body.key?(field) }

  if missing_fields.any?
    status 400
    return json(success: false, message: 'Missing required fields')
  end

  response = $simulator.initiate_mpesa_payment(
    phone_number: request_body[:phone_number],
    amount: request_body[:amount],
    account_reference: request_body[:account_reference] || 'TEST',
    description: request_body[:description] || 'Payment',
    callback_url: request_body[:callback_url]
  )

  StructuredLogger.info(
    event: 'payment.mpesa.initiated',
    request_id: Security.request_id(request),
    transaction_id: response[:transaction_id],
    amount: request_body[:amount],
    phone_number: request_body[:phone_number]
  )

  transaction_id = response[:transaction_id]
  auto_complete = request_body.fetch(:auto_complete, true)
  force_success = request_body[:force_success]

  schedule_callback(transaction_id, 2, force_success) if auto_complete

  json response
end

post '/api/payments/mpesa/callback' do
  request_body = JSON.parse(request.body.read, symbolize_names: true)

  unless request_body[:transaction_id]
    status 400
    return json(success: false, message: 'Missing transaction_id')
  end

  callback = $simulator.simulate_mpesa_callback(
    request_body[:transaction_id],
    force_success: request_body[:force_success]
  )

  json callback
end

post '/api/payments/bank-transfer' do
  request_body = JSON.parse(request.body.read, symbolize_names: true)

  required_fields = %i[account_number bank_code amount]
  missing_fields = required_fields.reject { |field| request_body.key?(field) }

  if missing_fields.any?
    status 400
    return json(success: false, message: 'Missing required fields')
  end

  response = $simulator.initiate_bank_transfer(
    account_number: request_body[:account_number],
    bank_code: request_body[:bank_code],
    amount: request_body[:amount],
    reference: request_body[:reference] || 'TEST',
    narration: request_body[:narration] || 'Payment',
    callback_url: request_body[:callback_url]
  )

  StructuredLogger.info(
    event: 'payment.bank.initiated',
    request_id: Security.request_id(request),
    transaction_id: response[:transaction_id],
    amount: request_body[:amount],
    account_number: request_body[:account_number]
  )

  transaction_id = response[:transaction_id]
  auto_complete = request_body.fetch(:auto_complete, true)
  force_success = request_body[:force_success]

  schedule_bank_completion(transaction_id, 3, force_success) if auto_complete

  json response
end

post '/api/payments/bank-transfer/complete' do
  request_body = JSON.parse(request.body.read, symbolize_names: true)

  unless request_body[:transaction_id]
    status 400
    return json(success: false, message: 'Missing transaction_id')
  end

  result = $simulator.simulate_bank_transfer_completion(
    request_body[:transaction_id],
    force_success: request_body[:force_success]
  )

  json result
end

get '/api/payments/:transaction_id' do
  result = $simulator.get_transaction_status(params[:transaction_id])

  unless result[:success]
    status 404
    return json result
  end

  json result
end

get '/api/payments' do
  result = $simulator.list_transactions(
    status: params[:status],
    method: params[:method]
  )

  json result
end

post '/api/payments/reset' do
  halt_json 404, success: false, message: 'Not found' unless AppConfig.reset_enabled?
  require_admin_key! if AppConfig.production?

  $simulator.reset_transactions
  StructuredLogger.warn(event: 'transactions.reset', request_id: Security.request_id(request))

  json(success: true, message: 'All transactions cleared')
end

not_found do
  json(success: false, message: 'Endpoint not found')
end

error do
  StructuredLogger.error(
    event: 'request.error',
    request_id: Security.request_id(request),
    path: request.path_info,
    error: env['sinatra.error']&.message
  )
  json(success: false, message: 'Internal server error')
end

configure do
  if AppConfig.production? && !AppConfig.auth_configured?
    StructuredLogger.error(
      event: 'startup.warning',
      message: 'API_KEY is not set — all authenticated routes will return 503'
    )
  end

  next unless __FILE__ == $PROGRAM_NAME

  puts "\n#{'=' * 60}"
  puts 'Payment Simulator API'
  puts "Environment: #{AppConfig.rack_env}"
  puts '=' * 60
  puts "\nAuth: #{AppConfig.auth_required? ? 'enabled' : 'disabled (local only)'}"
  puts "CORS origins: #{AppConfig.cors_enabled? ? AppConfig.allowed_origins.join(', ') : 'localhost only'}"
  puts "\nStarting server on http://localhost:#{settings.port}"
  puts "#{'=' * 60}\n"
end
