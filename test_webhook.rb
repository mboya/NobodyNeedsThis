#!/usr/bin/env ruby
# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'

def check_webhook_receiver_running
  puts "\n1. Checking if webhook receiver is running..."
  begin
    uri = URI('http://localhost:4567/')
    response = Net::HTTP.get_response(uri)
    
    if response.is_a?(Net::HTTPSuccess)
      puts "   ✓ Webhook receiver is running on port 4567"
      return true
    else
      puts "   ✗ Webhook receiver responded but not healthy"
      return false
    end
  rescue Errno::ECONNREFUSED
    puts "   ✗ Webhook receiver is not running!"
    puts "   ℹ️  Start it with: ruby webhook_receiver.rb"
    return false
  end
end

def check_payment_simulator_running
  puts "\n2. Checking if payment simulator is running..."
  begin
    uri = URI('http://localhost:3000/api/health')
    response = Net::HTTP.get_response(uri)
    
    if response.is_a?(Net::HTTPSuccess)
      puts "   ✓ Payment simulator is running on port 3000"
      return true
    else
      puts "   ✗ Payment simulator responded but not healthy"
      return false
    end
  rescue Errno::ECONNREFUSED
    puts "   ✗ Payment simulator is not running!"
    puts "   ℹ️  Start it with: bundle exec puma app.rb -p 3000"
    return false
  end
end

def test_mpesa_webhook
  puts "\n" + "=" * 70
  puts "Testing M-Pesa Payment with Webhook"
  puts "=" * 70
  
  puts "\n3. Initiating M-Pesa payment with webhook URL..."
  uri = URI('http://localhost:3000/api/payments/mpesa/stk-push')
  http = Net::HTTP.new(uri.host, uri.port)
  request = Net::HTTP::Post.new(uri.path, 'Content-Type' => 'application/json')
  request.body = {
    phone_number: '254712345678',
    amount: 1500.00,
    account_reference: 'WEBHOOK-TEST-001',
    callback_url: 'http://localhost:4567/webhooks/mpesa',
    auto_complete: true,
    force_success: true
  }.to_json
  
  response = http.request(request)
  result = JSON.parse(response.body, symbolize_names: true)
  
  if result[:success]
    puts "   ✓ Payment initiated: #{result[:transaction_id]}"
    transaction_id = result[:transaction_id]
    
    puts "\n4. Waiting for webhook callback (3 seconds)..."
    sleep 3
    
    puts "\n5. Checking payment status..."
    status_uri = URI("http://localhost:3000/api/payments/#{transaction_id}")
    status_response = Net::HTTP.get_response(status_uri)
    status = JSON.parse(status_response.body, symbolize_names: true)
    
    if status[:success]
      txn = status[:transaction]
      puts "   Status: #{txn[:status]}"
      
      if txn[:webhook_sent]
        webhook_result = txn[:webhook_result]
        if webhook_result[:success]
          puts "   ✅ Webhook delivered successfully!"
          puts "   ✓ Webhook URL: #{txn[:callback_url]}"
          puts "   ✓ HTTP Status: #{webhook_result[:status_code]}"
        else
          puts "   ❌ Webhook delivery failed!"
          puts "   ✗ Error: #{webhook_result[:error]}"
        end
      else
        puts "   ℹ️  No webhook was configured for this transaction"
      end
    end
    
    puts "\n6. Checking webhook receiver for received callbacks..."
    webhooks_uri = URI('http://localhost:4567/webhooks')
    webhooks_response = Net::HTTP.get_response(webhooks_uri)
    webhooks = JSON.parse(webhooks_response.body, symbolize_names: true)
    
    puts "   Total webhooks received: #{webhooks[:count]}"
    
    # Find our webhook
    our_webhook = webhooks[:webhooks].find do |wh|
      wh[:type] == 'mpesa' &&
        wh[:payload][:Body][:stkCallback][:MerchantRequestID] == result[:checkout_request_id]
    end
    
    if our_webhook
      puts "   ✅ Found our webhook in receiver!"
      puts "   ✓ Received at: #{our_webhook[:timestamp]}"
      callback = our_webhook[:payload][:Body][:stkCallback]
      puts "   ✓ Result Code: #{callback[:ResultCode]}"
      
      if callback[:ResultCode] == 0
        metadata = callback[:CallbackMetadata][:Item]
        receipt = metadata.find { |item| item[:Name] == 'MpesaReceiptNumber' }[:Value]
        puts "   ✓ Receipt: #{receipt}"
      end
    else
      puts "   ❌ Webhook not found in receiver"
    end
  
  else
    puts "   ❌ Failed to initiate payment: #{result[:message]}"
  end
end

def test_bank_webhook
  puts "\n" + "=" * 70
  puts "Testing Bank Transfer with Webhook"
  puts "=" * 70
  
  puts "\n7. Initiating bank transfer with webhook URL..."
  uri = URI('http://localhost:3000/api/payments/bank-transfer')
  http = Net::HTTP.new(uri.host, uri.port)
  request = Net::HTTP::Post.new(uri.path, 'Content-Type' => 'application/json')
  request.body = {
    account_number: '1234567890',
    bank_code: '01',
    amount: 10_000.00,
    reference: 'WEBHOOK-TEST-002',
    callback_url: 'http://localhost:4567/webhooks/bank',
    auto_complete: true,
    force_success: true
  }.to_json
  
  response = http.request(request)
  result = JSON.parse(response.body, symbolize_names: true)
  
  if result[:success]
    puts "   ✓ Transfer initiated: #{result[:transaction_id]}"
    transaction_id = result[:transaction_id]
    
    puts "\n8. Waiting for webhook callback (4 seconds)..."
    sleep 4
    
    puts "\n9. Checking transfer status..."
    status_uri = URI("http://localhost:3000/api/payments/#{transaction_id}")
    status_response = Net::HTTP.get_response(status_uri)
    status = JSON.parse(status_response.body, symbolize_names: true)
    
    if status[:success]
      txn = status[:transaction]
      puts "   Status: #{txn[:status]}"
      
      if txn[:webhook_sent]
        webhook_result = txn[:webhook_result]
        if webhook_result[:success]
          puts "   ✅ Webhook delivered successfully!"
          puts "   ✓ Webhook URL: #{txn[:callback_url]}"
          puts "   ✓ HTTP Status: #{webhook_result[:status_code]}"
        else
          puts "   ❌ Webhook delivery failed!"
          puts "   ✗ Error: #{webhook_result[:error]}"
        end
      end
    end
    
    puts "\n10. Checking webhook receiver for bank callbacks..."
    webhooks_uri = URI('http://localhost:4567/webhooks')
    webhooks_response = Net::HTTP.get_response(webhooks_uri)
    webhooks = JSON.parse(webhooks_response.body, symbolize_names: true)
    
    bank_webhooks = webhooks[:webhooks].select { |wh| wh[:type] == 'bank' }
    puts "   Bank transfer webhooks received: #{bank_webhooks.length}"
    
    # Find our webhook
    our_webhook = bank_webhooks.find do |wh|
      wh[:payload][:transaction_id] == transaction_id
    end
    
    if our_webhook
      puts "   ✅ Found our webhook in receiver!"
      puts "   ✓ Received at: #{our_webhook[:timestamp]}"
      payload = our_webhook[:payload]
      puts "   ✓ Status: #{payload[:status]}"
      puts "   ✓ Bank Reference: #{payload[:bank_reference]}"
    else
      puts "   ❌ Webhook not found in receiver"
    end
  
  else
    puts "   ❌ Failed to initiate transfer: #{result[:message]}"
  end
end

# Main execution
puts "\n" + "=" * 70
puts "Payment Simulator - Webhook Test"
puts "=" * 70

receiver_running = check_webhook_receiver_running
simulator_running = check_payment_simulator_running

if !receiver_running || !simulator_running
  puts "\n" + "=" * 70
  puts "⚠️  Prerequisites not met"
  puts "=" * 70
  puts "\nPlease ensure both servers are running:"
  puts "  Terminal 1: bundle exec puma app.rb -p 3000"
  puts "  Terminal 2: ruby webhook_receiver.rb"
  puts "\nThen run this test again."
  exit 1
end

# Clear previous webhooks
puts "\nClearing previous webhooks..."
uri = URI('http://localhost:4567/webhooks/clear')
Net::HTTP.post(uri, '{}', 'Content-Type' => 'application/json')
puts "   ✓ Webhooks cleared"

# Run tests
test_mpesa_webhook
sleep 2
test_bank_webhook

puts "\n" + "=" * 70
puts "✅ Webhook Tests Complete!"
puts "=" * 70
puts "\nYou can view all webhooks at: http://localhost:4567/webhooks"
puts ""