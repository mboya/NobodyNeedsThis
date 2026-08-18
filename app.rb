# frozen_string_literal: true

require 'sinatra'
require 'sinatra/json'
require 'sinatra/cors'
require 'securerandom'
require_relative 'lib/app_config'
require_relative 'lib/structured_logger'
require_relative 'lib/rate_limiter'
require_relative 'lib/security'
require_relative 'lib/api_key_store'
require_relative 'lib/tenant_registry'
require_relative 'lib/api_docs'
require_relative 'lib/docs_helpers'
require_relative 'payment_simulator'
require_relative 'lib/pesalink'

PaymentSimulator::Simulator.include(PaymentSimulator::Pesalink)

set :views, File.expand_path('views', __dir__)

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

$general_rate_limiter = RateLimiter.new(
  max_requests: AppConfig.rate_limit_max,
  window_seconds: AppConfig.rate_limit_window_seconds
)
$webhook_rate_limiter = RateLimiter.new(
  max_requests: AppConfig.rate_limit_webhook_max,
  window_seconds: AppConfig.rate_limit_window_seconds
)
$key_registration_rate_limiter = RateLimiter.new(
  max_requests: ENV.fetch('KEY_REGISTRATION_RATE_LIMIT', '10').to_i,
  window_seconds: ENV.fetch('KEY_REGISTRATION_RATE_WINDOW', '3600').to_i
)

def halt_json(status_code, payload)
  halt status_code, payload.to_json
end

def present_field?(value)
  !(value.nil? || value.to_s.strip.empty?)
end

def infer_pesalink_type(body)
  explicit = body[:type].to_s.strip.downcase
  return explicit unless explicit.empty?

  present_field?(body[:phone_number]) && !present_field?(body[:account_number]) ? 'phone' : 'account'
end

def require_api_key!
  return if Security.public_path?(request.path_info, method: request.request_method)
  return unless AppConfig.auth_required?

  if AppConfig.production? && !AppConfig.auth_configured?
    StructuredLogger.error(event: 'auth.misconfigured')
    halt_json 503, success: false, message: 'API authentication is not configured'
  end

  key = Security.extract_api_key(request)
  if Security.valid_api_key?(key)
    request.env['payment_simulator.api_key'] = key
    return
  end

  StructuredLogger.warn(
    event: 'auth.denied',
    path: request.path_info,
    method: request.request_method,
    client_ip: Security.client_ip(request)
  )
  halt_json 401, success: false, message: 'Unauthorized'
end

def current_api_key
  request.env['payment_simulator.api_key']
end

def current_simulator
  tenant_key = current_api_key || 'anonymous'
  TenantRegistry.for(tenant_key)
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
  return if request.request_method == 'OPTIONS'

  limiter = if request.post? && request.path_info == '/api/keys'
              $key_registration_rate_limiter
            elsif Security.public_path?(request.path_info, method: request.request_method)
              return
            elsif Security.webhook_path?(request.path_info)
              $webhook_rate_limiter
            else
              $general_rate_limiter
            end
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

def schedule_callback(transaction_id, delay, force_success = nil, simulator:)
  Thread.new do
    sleep delay
    result = simulator.simulate_mpesa_callback(transaction_id, force_success: force_success)
    result_code = result.dig(:Body, :stkCallback, :ResultCode)
    txn = simulator.transactions[transaction_id]

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

def schedule_bank_completion(transaction_id, delay, force_success = nil, simulator:)
  Thread.new do
    sleep delay
    result = simulator.simulate_bank_transfer_completion(transaction_id, force_success: force_success)
    txn = simulator.transactions[transaction_id]

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

def schedule_pesalink_completion(transaction_id, delay, force_outcome = nil, simulator:)
  Thread.new do
    sleep delay
    result = simulator.simulate_pesalink_completion(transaction_id, force_outcome: force_outcome)
    txn = simulator.transactions[transaction_id]

    StructuredLogger.info(
      event: 'callback.pesalink.completed',
      transaction_id: transaction_id,
      response_code: result[:response_code],
      webhook_sent: txn&.dig(:webhook_sent) == true
    )
  rescue StandardError => e
    StructuredLogger.error(
      event: 'callback.pesalink.failed',
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

get '/' do
  redirect '/docs'
end

get '/docs' do
  base = "#{request.scheme}://#{request.host_with_port}"
  @page_title = 'Payment Simulator — API Docs'
  @base_url = base
  @environment = AppConfig.rack_env
  @auth_required = AppConfig.auth_required?
  @registration_enabled = AppConfig.registration_enabled?
  @endpoints = DocsHelpers.prepare_endpoints(base)
  @mpesa_codes = ApiDocs.mpesa_result_codes
  @pesalink_codes = ApiDocs.pesalink_result_codes
  content_type 'text/html'
  erb :docs, layout: :layout
end

get '/api' do
  json(
    service: 'payment-simulator',
    status: 'ok',
    health: '/api/health',
    docs: '/docs'
  )
end

# Health check (public, no auth)
get '/api/health' do
  json(
    status: 'healthy',
    service: 'payment-simulator',
    environment: AppConfig.rack_env,
    auth_required: AppConfig.auth_required?,
    registration_enabled: AppConfig.registration_enabled?,
    api_key_store: ApiKeyStore.using_redis? ? 'redis' : 'memory'
  )
end

# Self-service API key (public when registration is enabled)
post '/api/keys' do
  halt_json 403, success: false, message: 'API key registration is disabled' unless AppConfig.registration_enabled?

  key = ApiKeyStore.generate_key
  unless ApiKeyStore.register(key)
    halt_json 503, success: false, message: 'Could not register API key'
  end

  StructuredLogger.info(
    event: 'api_key.created',
    request_id: Security.request_id(request),
    client_ip: Security.client_ip(request),
    key_prefix: key[0, 12]
  )

  json(
    success: true,
    api_key: key,
    message: 'Save this key now — it will not be shown again. Use Authorization: Bearer <api_key> or X-API-Key header.'
  )
end

# Revoke the API key used on this request (does not apply to env/bootstrap keys)
delete '/api/keys' do
  key = current_api_key
  halt_json 401, success: false, message: 'Unauthorized' if key.nil? || key.empty?
  halt_json 400, success: false, message: 'Cannot revoke a bootstrap API key' if AppConfig.env_api_keys.include?(key)

  ApiKeyStore.revoke(key)
  TenantRegistry.reset!(key)

  StructuredLogger.info(
    event: 'api_key.revoked',
    request_id: Security.request_id(request),
    key_prefix: key[0, 12]
  )

  json(success: true, message: 'API key revoked')
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

  sim = current_simulator
  response = sim.initiate_mpesa_payment(
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

  schedule_callback(transaction_id, 2, force_success, simulator: sim) if auto_complete

  json response
end

post '/api/payments/mpesa/callback' do
  request_body = JSON.parse(request.body.read, symbolize_names: true)

  unless request_body[:transaction_id]
    status 400
    return json(success: false, message: 'Missing transaction_id')
  end

  callback = current_simulator.simulate_mpesa_callback(
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

  sim = current_simulator
  response = sim.initiate_bank_transfer(
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

  schedule_bank_completion(transaction_id, 3, force_success, simulator: sim) if auto_complete

  json response
end

post '/api/payments/bank-transfer/complete' do
  request_body = JSON.parse(request.body.read, symbolize_names: true)

  unless request_body[:transaction_id]
    status 400
    return json(success: false, message: 'Missing transaction_id')
  end

  result = current_simulator.simulate_bank_transfer_completion(
    request_body[:transaction_id],
    force_success: request_body[:force_success]
  )

  json result
end

get '/api/payments/pesalink/banks' do
  json(
    success: true,
    note: 'Illustrative sort codes, not the official IPSL participant list.',
    banks: current_simulator.pesalink_banks
  )
end

post '/api/payments/pesalink/name-inquiry' do
  request_body = JSON.parse(request.body.read, symbolize_names: true)

  has_account = present_field?(request_body[:bank_code]) && present_field?(request_body[:account_number])
  has_phone = present_field?(request_body[:phone_number])

  unless has_account || has_phone
    status 400
    return json(success: false, message: 'Provide bank_code and account_number, or phone_number')
  end

  result = if has_account
             current_simulator.pesalink_name_inquiry(
               bank_code: request_body[:bank_code],
               account_number: request_body[:account_number]
             )
           else
             current_simulator.pesalink_name_inquiry(phone_number: request_body[:phone_number])
           end

  unless result[:success]
    status 404
    return json result
  end

  json result
end

post '/api/payments/pesalink/send' do
  request_body = JSON.parse(request.body.read, symbolize_names: true)
  type = infer_pesalink_type(request_body)

  unless %w[account phone].include?(type)
    status 400
    return json(success: false, message: "type must be 'account' (STA) or 'phone' (STP)")
  end

  missing = [:amount]
  if type == 'phone'
    missing << :phone_number
  else
    missing.concat(%i[bank_code account_number])
  end
  missing.select! { |field| !present_field?(request_body[field]) }

  if missing.any?
    status 400
    return json(success: false, message: 'Missing required fields')
  end

  sim = current_simulator
  response = sim.initiate_pesalink_transfer(
    type: type,
    bank_code: request_body[:bank_code],
    account_number: request_body[:account_number],
    phone_number: request_body[:phone_number],
    amount: request_body[:amount],
    reference: request_body[:reference] || 'TEST',
    narration: request_body[:narration] || 'Payment',
    callback_url: request_body[:callback_url]
  )

  unless response[:success]
    status 422
    return json response
  end

  StructuredLogger.info(
    event: 'payment.pesalink.initiated',
    request_id: Security.request_id(request),
    transaction_id: response[:transaction_id],
    amount: request_body[:amount],
    type: type
  )

  auto_complete = request_body.fetch(:auto_complete, true)
  force_outcome = request_body[:force_outcome]
  schedule_pesalink_completion(response[:transaction_id], 2, force_outcome, simulator: sim) if auto_complete

  json response
end

post '/api/payments/pesalink/complete' do
  request_body = JSON.parse(request.body.read, symbolize_names: true)

  unless request_body[:transaction_id]
    status 400
    return json(success: false, message: 'Missing transaction_id')
  end

  result = current_simulator.simulate_pesalink_completion(
    request_body[:transaction_id],
    force_outcome: request_body[:force_outcome]
  )

  json result
end

get '/api/payments/:transaction_id' do
  result = current_simulator.get_transaction_status(params[:transaction_id])

  unless result[:success]
    status 404
    return json result
  end

  json result
end

get '/api/payments' do
  result = current_simulator.list_transactions(
    status: params[:status],
    method: params[:method]
  )

  json result
end

post '/api/payments/reset' do
  halt_json 404, success: false, message: 'Not found' unless AppConfig.reset_enabled?
  require_admin_key! if AppConfig.production?

  current_simulator.reset_transactions
  StructuredLogger.warn(event: 'transactions.reset', request_id: Security.request_id(request))

  json(success: true, message: 'All transactions cleared')
end

# Sinatra runs this for any HTTP 404, including routes that set status 404
# themselves (name-inquiry miss, unknown transaction). Keep a body the
# route already wrote; only fill in unmatched paths.
not_found do
  existing = Array(response.body).join
  next unless existing.empty?

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
      message: 'Neither API_KEY nor ENABLE_API_KEY_REGISTRATION is configured'
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
