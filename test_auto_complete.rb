#!/usr/bin/env ruby
# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'

def test_auto_complete_mpesa
  puts "\n" + "=" * 60
  puts "Testing M-Pesa Auto-Complete"
  puts "=" * 60
  
  # Step 1: Initiate payment with auto_complete=true
  puts "\n1. Initiating M-Pesa payment with auto_complete=true..."
  uri = URI('http://localhost:3000/api/payments/mpesa/stk-push')
  http = Net::HTTP.new(uri.host, uri.port)
  request = Net::HTTP::Post.new(uri.path, 'Content-Type' => 'application/json')
  request.body = {
    phone_number: '254712345678',
    amount: 1000.00,
    account_reference: 'TEST-AUTO',
    auto_complete: true,
    force_success: true
  }.to_json
  
  response = http.request(request)
  result = JSON.parse(response.body, symbolize_names: true)
  
  if result[:success]
    puts "   ✓ Payment initiated: #{result[:transaction_id]}"
    puts "   ✓ Status: #{result[:status]}"
    transaction_id = result[:transaction_id]
    
    # Step 2: Wait for auto-complete (should happen in ~2 seconds)
    puts "\n2. Waiting for auto-complete callback (2 seconds)..."
    sleep 1
    puts "   ⏳ Checking status after 1 second..."
    check_status(transaction_id)
    
    sleep 1.5
    puts "\n   ⏳ Checking status after 2.5 seconds..."
    check_status(transaction_id)
    
    sleep 1
    puts "\n   ⏳ Final check after 3.5 seconds..."
    final_status = check_status(transaction_id)
    
    # Step 3: Verify completion
    puts "\n3. Verification:"
    if final_status[:transaction][:status] == 'completed'
      puts "   ✅ SUCCESS! Auto-complete is working!"
      puts "   ✓ Final status: #{final_status[:transaction][:status]}"
      puts "   ✓ Receipt: #{final_status[:transaction][:mpesa_receipt]}"
    else
      puts "   ❌ FAILED! Payment did not auto-complete"
      puts "   ✗ Final status: #{final_status[:transaction][:status]}"
      puts "   ℹ️  This means the async callback is not executing"
    end
  else
    puts "   ❌ Failed to initiate payment: #{result[:message]}"
  end
end

def test_auto_complete_bank
  puts "\n" + "=" * 60
  puts "Testing Bank Transfer Auto-Complete"
  puts "=" * 60
  
  # Step 1: Initiate transfer with auto_complete=true
  puts "\n1. Initiating bank transfer with auto_complete=true..."
  uri = URI('http://localhost:3000/api/payments/bank-transfer')
  http = Net::HTTP.new(uri.host, uri.port)
  request = Net::HTTP::Post.new(uri.path, 'Content-Type' => 'application/json')
  request.body = {
    account_number: '1234567890',
    bank_code: '01',
    amount: 3000.00,
    reference: 'TEST-AUTO',
    auto_complete: true,
    force_success: true
  }.to_json
  
  response = http.request(request)
  result = JSON.parse(response.body, symbolize_names: true)
  
  if result[:success]
    puts "   ✓ Transfer initiated: #{result[:transaction_id]}"
    puts "   ✓ Status: #{result[:status]}"
    transaction_id = result[:transaction_id]
    
    # Step 2: Wait for auto-complete (should happen in ~3 seconds)
    puts "\n2. Waiting for auto-complete (3 seconds)..."
    sleep 1.5
    puts "   ⏳ Checking status after 1.5 seconds..."
    check_status(transaction_id)
    
    sleep 2
    puts "\n   ⏳ Checking status after 3.5 seconds..."
    check_status(transaction_id)
    
    sleep 1
    puts "\n   ⏳ Final check after 4.5 seconds..."
    final_status = check_status(transaction_id)
    
    # Step 3: Verify completion
    puts "\n3. Verification:"
    if final_status[:transaction][:status] == 'completed'
      puts "   ✅ SUCCESS! Auto-complete is working!"
      puts "   ✓ Final status: #{final_status[:transaction][:status]}"
      puts "   ✓ Bank Reference: #{final_status[:transaction][:bank_reference]}"
    else
      puts "   ❌ FAILED! Transfer did not auto-complete"
      puts "   ✗ Final status: #{final_status[:transaction][:status]}"
      puts "   ℹ️  This means the async callback is not executing"
    end
  else
    puts "   ❌ Failed to initiate transfer: #{result[:message]}"
  end
end

def check_status(transaction_id)
  uri = URI("http://localhost:3000/api/payments/#{transaction_id}")
  response = Net::HTTP.get_response(uri)
  result = JSON.parse(response.body, symbolize_names: true)
  
  if result[:success]
    status = result[:transaction][:status]
    puts "      Status: #{status}"
    
    case status
    when 'pending'
      puts "      ℹ️  Still pending (callback hasn't executed yet)"
    when 'processing'
      puts "      ℹ️  Processing (callback hasn't executed yet)"
    when 'completed'
      puts "      ✓ Completed!"
    when 'failed'
      puts "      ✗ Failed"
    end
  end
  
  result
end

def check_server_health
  puts "\n" + "=" * 60
  puts "Checking Server Status"
  puts "=" * 60
  
  begin
    uri = URI('http://localhost:3000/api/health')
    response = Net::HTTP.get_response(uri)
    
    if response.is_a?(Net::HTTPSuccess)
      puts "✓ Server is running and healthy!"
      
      # Check thread status
      uri = URI('http://localhost:3000/api/debug/threads')
      response = Net::HTTP.get_response(uri)
      threads = JSON.parse(response.body, symbolize_names: true)
      puts "✓ Active threads: #{threads[:thread_count]}"
      
      return true
    else
      puts "✗ Server responded but not healthy"
      return false
    end
  rescue Errno::ECONNREFUSED
    puts "✗ Server is not running!"
    puts "Please start the server with: ruby app.rb"
    return false
  end
end

# Main execution
puts "\n" + "=" * 60
puts "Payment Simulator - Auto-Complete Test"
puts "=" * 60

if check_server_health
  test_auto_complete_mpesa
  
  puts "\n"
  sleep 2
  
  test_auto_complete_bank
  
  puts "\n" + "=" * 60
  puts "Test Complete!"
  puts "=" * 60
  puts ""
else
  puts "\nCannot run tests without the server running."
  exit 1
end
