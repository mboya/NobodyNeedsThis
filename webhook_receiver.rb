#!/usr/bin/env ruby
# frozen_string_literal: true

require 'sinatra'
require 'sinatra/json'
require 'json'

# Simple webhook receiver for testing payment callbacks
# Run this on a different port than the payment simulator

set :port, 4567
set :bind, '0.0.0.0'

# Store received webhooks in memory for inspection
$received_webhooks = []

# M-Pesa webhook endpoint
post '/webhooks/mpesa' do
  request_body = JSON.parse(request.body.read, symbolize_names: true)
  
  puts "\n" + "=" * 60
  puts "📥 M-PESA WEBHOOK RECEIVED"
  puts "=" * 60
  puts "Timestamp: #{Time.now}"
  puts "Payload:"
  puts JSON.pretty_generate(request_body)
  puts "=" * 60
  
  # Extract important information
  callback = request_body[:Body][:stkCallback]
  result_code = callback[:ResultCode]
  
  if result_code == 0
    # Payment successful
    metadata = callback[:CallbackMetadata][:Item]
    amount = metadata.find { |item| item[:Name] == 'Amount' }[:Value]
    receipt = metadata.find { |item| item[:Name] == 'MpesaReceiptNumber' }[:Value]
    phone = metadata.find { |item| item[:Name] == 'PhoneNumber' }[:Value]
    
    puts "✅ PAYMENT SUCCESSFUL"
    puts "   Amount: KES #{amount}"
    puts "   Receipt: #{receipt}"
    puts "   Phone: #{phone}"
    
    # Here you would typically:
    # 1. Update your database
    # 2. Mark order as paid
    # 3. Send confirmation email
    # 4. Trigger fulfillment process
  
  else
    # Payment failed
    puts "❌ PAYMENT FAILED"
    puts "   Reason: #{callback[:ResultDesc]}"
    
    # Here you would typically:
    # 1. Update transaction status
    # 2. Notify customer
    # 3. Allow retry
  end
  
  # Store for inspection
  $received_webhooks << {
    type: 'mpesa',
    timestamp: Time.now.iso8601,
    payload: request_body
  }
  
  # Return 200 OK to acknowledge receipt
  status 200
  json(success: true, message: 'Webhook received')
end

# Bank transfer webhook endpoint
post '/webhooks/bank' do
  request_body = JSON.parse(request.body.read, symbolize_names: true)
  
  puts "\n" + "=" * 60
  puts "📥 BANK TRANSFER WEBHOOK RECEIVED"
  puts "=" * 60
  puts "Timestamp: #{Time.now}"
  puts "Payload:"
  puts JSON.pretty_generate(request_body)
  puts "=" * 60
  
  if request_body[:success]
    # Transfer successful
    puts "✅ TRANSFER SUCCESSFUL"
    puts "   Transaction ID: #{request_body[:transaction_id]}"
    puts "   Bank Reference: #{request_body[:bank_reference]}"
    puts "   Amount: KES #{request_body[:amount]}"
    puts "   Account: #{request_body[:account_number]}"
    
    # Here you would typically:
    # 1. Update payment record
    # 2. Notify recipient
    # 3. Update accounting system
  
  else
    # Transfer failed
    puts "❌ TRANSFER FAILED"
    puts "   Reason: #{request_body[:message]}"
    
    # Here you would typically:
    # 1. Update transaction status
    # 2. Alert admin
    # 3. Investigate issue
  end
  
  # Store for inspection
  $received_webhooks << {
    type: 'bank',
    timestamp: Time.now.iso8601,
    payload: request_body
  }
  
  # Return 200 OK
  status 200
  json(success: true, message: 'Webhook received')
end

# Endpoint to view all received webhooks
get '/webhooks' do
  json(
    count: $received_webhooks.length,
    webhooks: $received_webhooks
  )
end

# Clear all webhooks
post '/webhooks/clear' do
  $received_webhooks = []
  json(success: true, message: 'All webhooks cleared')
end

# Homepage with instructions
get '/' do
  erb :index
end

# Server startup
configure do
  puts "\n" + "=" * 60
  puts "Webhook Receiver - Running on http://localhost:4567"
  puts "=" * 60
  puts "\nEndpoints:"
  puts "  POST   /webhooks/mpesa   - Receive M-Pesa callbacks"
  puts "  POST   /webhooks/bank    - Receive bank transfer callbacks"
  puts "  GET    /webhooks         - View all received webhooks"
  puts "  POST   /webhooks/clear   - Clear webhook history"
  puts "\nExample usage with payment simulator:"
  puts "  curl -X POST http://localhost:3000/api/payments/mpesa/stk-push \\"
  puts "    -H 'Content-Type: application/json' \\"
  puts "    -d '{"
  puts "      \"phone_number\": \"254712345678\","
  puts "      \"amount\": 1000,"
  puts "      \"callback_url\": \"http://localhost:4567/webhooks/mpesa\""
  puts "    }'"
  puts "\n" + "=" * 60 + "\n"
end

__END__

@@index
<!DOCTYPE html>
<html>
<head>
  <title>Webhook Receiver</title>
  <style>
    body {
      font-family: Arial, sans-serif;
      max-width: 800px;
      margin: 50px auto;
      padding: 20px;
      background: #f5f5f5;
    }
    .container {
      background: white;
      padding: 30px;
      border-radius: 10px;
      box-shadow: 0 2px 10px rgba(0,0,0,0.1);
    }
    h1 { color: #333; }
    pre {
      background: #f5f5f5;
      padding: 15px;
      border-radius: 5px;
      overflow-x: auto;
    }
    code { color: #c7254e; }
    .endpoint {
      margin: 15px 0;
      padding: 10px;
      background: #e8f5e9;
      border-left: 4px solid #4caf50;
    }
  </style>
</head>
<body>
  <div class="container">
    <h1>🔔 Webhook Receiver</h1>
    <p>This server is ready to receive payment callbacks from the payment simulator.</p>
    
    <h2>Available Endpoints</h2>
    
    <div class="endpoint">
      <strong>POST /webhooks/mpesa</strong>
      <p>Receives M-Pesa payment callbacks</p>
    </div>
    
    <div class="endpoint">
      <strong>POST /webhooks/bank</strong>
      <p>Receives bank transfer callbacks</p>
    </div>
    
    <div class="endpoint">
      <strong>GET /webhooks</strong>
      <p>View all received webhooks</p>
    </div>
    
    <h2>Example: Initiate Payment with Webhook</h2>
    <pre><code>curl -X POST http://localhost:3000/api/payments/mpesa/stk-push \
  -H 'Content-Type: application/json' \
  -d '{
    "phone_number": "254712345678",
    "amount": 1000,
    "callback_url": "http://localhost:4567/webhooks/mpesa",
    "auto_complete": true
  }'</code></pre>
    
    <h2>Check Received Webhooks</h2>
    <p>Visit <a href="/webhooks">/webhooks</a> to see all received callbacks</p>
  </div>
</body>
</html>