# frozen_string_literal: true

require 'sinatra'
require 'sinatra/json'
require 'sinatra/cors'
require_relative 'payment_simulator'

# Configure Sinatra
set :port, 3000
set :bind, '0.0.0.0'

# Enable CORS
set :allow_origin, '*'
set :allow_methods, 'GET,POST,PUT,DELETE,OPTIONS'
set :allow_headers, 'content-type,if-modified-since'

# Initialize the simulator
$simulator = PaymentSimulator::Simulator.new(success_rate: 0.95)

# Helper to schedule async callbacks
def schedule_callback(transaction_id, delay, force_success = nil)
  Thread.new do
    begin
      sleep delay
      result = $simulator.simulate_mpesa_callback(transaction_id, force_success: force_success)
      
      # Log callback execution
      result_code = result[:Body][:stkCallback][:ResultCode]
      puts "[CALLBACK] M-Pesa callback completed for #{transaction_id}: #{result_code}"
      
      # Check if webhook was sent
      txn = $simulator.transactions[transaction_id]
      if txn[:webhook_sent]
        webhook_result = txn[:webhook_result]
        if webhook_result[:success]
          puts "[WEBHOOK] ✓ Successfully sent to #{txn[:callback_url]}"
        else
          puts "[WEBHOOK] ✗ Failed to send to #{txn[:callback_url]}: #{webhook_result[:error]}"
        end
      end
    rescue StandardError => e
      puts "[ERROR] Failed to process M-Pesa callback: #{e.message}"
      puts e.backtrace.first(3)
    end
  end
end

def schedule_bank_completion(transaction_id, delay, force_success = nil)
  Thread.new do
    begin
      sleep delay
      result = $simulator.simulate_bank_transfer_completion(transaction_id, force_success: force_success)
      puts "[CALLBACK] Bank transfer completed for #{transaction_id}: #{result[:status]}"
      
      # Check if webhook was sent
      txn = $simulator.transactions[transaction_id]
      if txn[:webhook_sent]
        webhook_result = txn[:webhook_result]
        if webhook_result[:success]
          puts "[WEBHOOK] ✓ Successfully sent to #{txn[:callback_url]}"
        else
          puts "[WEBHOOK] ✗ Failed to send to #{txn[:callback_url]}: #{webhook_result[:error]}"
        end
      end
    rescue StandardError => e
      puts "[ERROR] Failed to process bank transfer: #{e.message}"
      puts e.backtrace.first(3)
    end
  end
end

# Routes

# Health check
get '/api/health' do
  json(status: 'healthy', service: 'payment-simulator')
end

# Debug endpoint to check thread status
get '/api/debug/threads' do
  json(
    thread_count: Thread.list.count,
    threads: Thread.list.map { |t| { status: t.status, alive: t.alive? } }
  )
end

# Initiate M-Pesa STK Push
post '/api/payments/mpesa/stk-push' do
  request_body = JSON.parse(request.body.read, symbolize_names: true)
  
  # Validate required fields
  required_fields = [:phone_number, :amount]
  missing_fields = required_fields.select { |field| !request_body.key?(field) }
  
  if missing_fields.any?
    status 400
    return json(success: false, message: 'Missing required fields')
  end
  
  # Initiate payment
  response = $simulator.initiate_mpesa_payment(
    phone_number: request_body[:phone_number],
    amount: request_body[:amount],
    account_reference: request_body[:account_reference] || 'TEST',
    description: request_body[:description] || 'Payment',
    callback_url: request_body[:callback_url]
  )
  
  # Schedule callback if auto_complete is enabled
  transaction_id = response[:transaction_id]
  auto_complete = request_body.fetch(:auto_complete, true)
  force_success = request_body[:force_success]
  
  if auto_complete
    schedule_callback(transaction_id, 2, force_success) # 2-second delay
  end
  
  json response
end

# Manual M-Pesa callback simulation
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

# Initiate bank transfer
post '/api/payments/bank-transfer' do
  request_body = JSON.parse(request.body.read, symbolize_names: true)
  
  # Validate required fields
  required_fields = [:account_number, :bank_code, :amount]
  missing_fields = required_fields.select { |field| !request_body.key?(field) }
  
  if missing_fields.any?
    status 400
    return json(success: false, message: 'Missing required fields')
  end
  
  # Initiate transfer
  response = $simulator.initiate_bank_transfer(
    account_number: request_body[:account_number],
    bank_code: request_body[:bank_code],
    amount: request_body[:amount],
    reference: request_body[:reference] || 'TEST',
    narration: request_body[:narration] || 'Payment',
    callback_url: request_body[:callback_url]
  )
  
  # Schedule completion if auto_complete is enabled
  transaction_id = response[:transaction_id]
  auto_complete = request_body.fetch(:auto_complete, true)
  force_success = request_body[:force_success]
  
  if auto_complete
    schedule_bank_completion(transaction_id, 3, force_success) # 3-second delay
  end
  
  json response
end

# Complete bank transfer manually
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

# Get payment status
get '/api/payments/:transaction_id' do
  result = $simulator.get_transaction_status(params[:transaction_id])
  
  unless result[:success]
    status 404
    return json result
  end
  
  json result
end

# List all payments
get '/api/payments' do
  status_filter = params[:status]
  method_filter = params[:method]
  
  result = $simulator.list_transactions(
    status: status_filter,
    method: method_filter
  )
  
  json result
end

# Reset all transactions
post '/api/payments/reset' do
  $simulator.reset_transactions
  
  json(success: true, message: 'All transactions cleared')
end

# 404 handler
not_found do
  json(success: false, message: 'Endpoint not found')
end

# Error handler
error do
  env['sinatra.error'].message
  json(success: false, message: 'Internal server error')
end

# Server startup message
configure do
  puts "\n#{'=' * 60}"
  puts 'Payment Simulator API - DEMO MODE (Sinatra)'
  puts '=' * 60
  puts "\nEndpoints:"
  puts '  POST   /api/payments/mpesa/stk-push'
  puts '  POST   /api/payments/mpesa/callback'
  puts '  POST   /api/payments/bank-transfer'
  puts '  POST   /api/payments/bank-transfer/complete'
  puts '  GET    /api/payments/<transaction_id>'
  puts '  GET    /api/payments'
  puts '  POST   /api/payments/reset'
  puts "\nStarting server on http://localhost:3000"
  puts "#{'=' * 60}\n"
end