#!/usr/bin/env ruby
# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'

# Payment Client for interacting with the payment simulator API
class PaymentClient
  def initialize(base_url = 'http://localhost:3000')
    @base_url = base_url
  end

  def mpesa_payment(phone_number:, amount:, reference: 'TEST', auto_complete: true, force_success: nil)
    uri = URI("#{@base_url}/api/payments/mpesa/stk-push")
    payload = {
      phone_number: phone_number,
      amount: amount,
      account_reference: reference,
      description: "Payment for #{reference}",
      auto_complete: auto_complete,
      force_success: force_success
    }

    make_request(uri, payload)
  end

  def bank_transfer(account_number:, bank_code:, amount:, reference: 'TEST', auto_complete: true, force_success: nil)
    uri = URI("#{@base_url}/api/payments/bank-transfer")
    payload = {
      account_number: account_number,
      bank_code: bank_code,
      amount: amount,
      reference: reference,
      narration: "Transfer for #{reference}",
      auto_complete: auto_complete,
      force_success: force_success
    }

    make_request(uri, payload)
  end

  def get_status(transaction_id)
    uri = URI("#{@base_url}/api/payments/#{transaction_id}")
    http = Net::HTTP.new(uri.host, uri.port)
    request = Net::HTTP::Get.new(uri.path)
    response = http.request(request)
    JSON.parse(response.body, symbolize_names: true)
  end

  def list_payments(status: nil, method: nil)
    uri = URI("#{@base_url}/api/payments")
    params = {}
    params[:status] = status if status
    params[:method] = method if method
    uri.query = URI.encode_www_form(params) if params.any?

    http = Net::HTTP.new(uri.host, uri.port)
    request = Net::HTTP::Get.new(uri.request_uri)
    response = http.request(request)
    JSON.parse(response.body, symbolize_names: true)
  end

  def reset
    uri = URI("#{@base_url}/api/payments/reset")
    make_request(uri, {})
  end

  private

  def make_request(uri, payload)
    http = Net::HTTP.new(uri.host, uri.port)
    request = Net::HTTP::Post.new(uri.path, 'Content-Type' => 'application/json')
    request.body = payload.to_json
    response = http.request(request)
    JSON.parse(response.body, symbolize_names: true)
  end
end

# Demo Scenarios

def demo_scenario_1_successful_mpesa
  puts "\n#{'=' * 70}"
  puts 'DEMO SCENARIO 1: Successful M-Pesa Payment'
  puts '=' * 70

  client = PaymentClient.new

  puts "\n1. Customer initiates payment of KES 1,500 for Order #12345..."
  response = client.mpesa_payment(
    phone_number: '254712345678',
    amount: 1500.00,
    reference: 'ORDER-12345',
    force_success: true
  )
  puts "   ✓ STK Push sent: #{response[:transaction_id]}"

  transaction_id = response[:transaction_id]

  puts "\n2. Waiting for customer to enter PIN..."
  3.times do |i|
    sleep 1
    print '   ' + '.' * (i + 1) + "\n"
  end

  puts "\n3. Checking payment status..."
  status = client.get_status(transaction_id)
  if status[:success]
    txn = status[:transaction]
    if txn[:status] == 'completed'
      puts '   ✓ Payment SUCCESSFUL!'
      puts "   ✓ M-Pesa Receipt: #{txn[:mpesa_receipt]}"
      puts "   ✓ Amount: KES #{txn[:amount]}"
    else
      puts "   ⏳ Payment status: #{txn[:status]}"
    end
  end
end

def demo_scenario_2_failed_mpesa
  puts "\n#{'=' * 70}"
  puts 'DEMO SCENARIO 2: Failed M-Pesa Payment (User Cancelled)'
  puts '=' * 70

  client = PaymentClient.new

  puts "\n1. Customer initiates payment of KES 2,000..."
  response = client.mpesa_payment(
    phone_number: '254798765432',
    amount: 2000.00,
    reference: 'ORDER-67890',
    force_success: false
  )
  puts "   ✓ STK Push sent: #{response[:transaction_id]}"

  transaction_id = response[:transaction_id]

  puts "\n2. Customer cancels the payment request..."
  sleep 3

  puts "\n3. Checking payment status..."
  status = client.get_status(transaction_id)
  if status[:success]
    txn = status[:transaction]
    if txn[:status] == 'failed'
      puts '   ✗ Payment FAILED!'
      puts "   ✗ Reason: #{txn[:result_description]}"
      puts '   → You can retry or use alternative payment method'
    end
  end
end

def demo_scenario_3_bank_transfer
  puts "\n#{'=' * 70}"
  puts 'DEMO SCENARIO 3: Bank Transfer Payment'
  puts '=' * 70

  client = PaymentClient.new

  puts "\n1. Initiating bank transfer of KES 50,000 to supplier..."
  response = client.bank_transfer(
    account_number: '1234567890',
    bank_code: '01',
    amount: 50_000.00,
    reference: 'INV-2024-001',
    force_success: true
  )
  puts "   ✓ Transfer initiated: #{response[:transaction_id]}"
  puts "   ✓ Status: #{response[:status]}"

  transaction_id = response[:transaction_id]

  puts "\n2. Processing transfer (bank processing time)..."
  4.times do |i|
    sleep 1
    status = client.get_status(transaction_id)
    puts "   #{'.' * (i + 1)} Status: #{status[:transaction][:status]}" if status[:success]
  end

  puts "\n3. Transfer completed!"
  final_status = client.get_status(transaction_id)
  if final_status[:success]
    txn = final_status[:transaction]
    if txn[:status] == 'completed'
      puts '   ✓ Transfer SUCCESSFUL!'
      puts "   ✓ Bank Reference: #{txn[:bank_reference]}"
      puts "   ✓ Amount: KES #{txn[:amount]}"
    end
  end
end

def demo_scenario_4_mixed_payments
  puts "\n#{'=' * 70}"
  puts 'DEMO SCENARIO 4: Multiple Payments Dashboard'
  puts '=' * 70

  client = PaymentClient.new

  # Reset for clean demo
  client.reset

  puts "\n1. Processing multiple payments..."

  # M-Pesa payment 1
  client.mpesa_payment(phone_number: '254711111111', amount: 1000, reference: 'ORD-001', force_success: true)
  puts '   ✓ M-Pesa payment 1 initiated'

  # M-Pesa payment 2
  client.mpesa_payment(phone_number: '254722222222', amount: 2500, reference: 'ORD-002', force_success: true)
  puts '   ✓ M-Pesa payment 2 initiated'

  # Bank transfer
  client.bank_transfer(account_number: '9876543210', bank_code: '02', amount: 10_000, reference: 'INV-001', force_success: true)
  puts '   ✓ Bank transfer initiated'

  # Failed M-Pesa
  client.mpesa_payment(phone_number: '254733333333', amount: 500, reference: 'ORD-003', force_success: false)
  puts '   ✓ M-Pesa payment 3 initiated'

  puts "\n2. Waiting for payments to process..."
  sleep 4

  puts "\n3. Payment Summary:"
  all_payments = client.list_payments

  completed = all_payments[:transactions].select { |t| t[:status] == 'completed' }
  failed = all_payments[:transactions].select { |t| t[:status] == 'failed' }

  puts "\n   Total Transactions: #{all_payments[:count]}"
  puts "   ✓ Completed: #{completed.length}"
  puts "   ✗ Failed: #{failed.length}"

  puts "\n   Completed Payments:"
  completed.each do |txn|
    method = txn[:method] == 'mpesa' ? 'M-Pesa' : 'Bank Transfer'
    puts "   - #{txn[:transaction_id]}: #{method} - KES #{txn[:amount]}"
  end
end

def demo_scenario_5_webhook_integration
  puts "\n#{'=' * 70}"
  puts 'DEMO SCENARIO 5: Webhook/Callback Integration'
  puts '=' * 70

  client = PaymentClient.new

  puts "\n1. Your app initiates payment (auto_complete=false for manual control)..."
  response = client.mpesa_payment(
    phone_number: '254700000000',
    amount: 3000.00,
    reference: 'ORDER-99999',
    auto_complete: false
  )

  transaction_id = response[:transaction_id]
  puts "   ✓ Transaction ID: #{transaction_id}"
  puts '   ✓ Your app stores this ID and waits for callback...'

  puts "\n2. Simulating manual callback trigger (e.g., when user enters PIN)..."
  sleep 2

  # Manually trigger callback
  uri = URI('http://localhost:3000/api/payments/mpesa/callback')
  http = Net::HTTP.new(uri.host, uri.port)
  request = Net::HTTP::Post.new(uri.path, 'Content-Type' => 'application/json')
  request.body = { transaction_id: transaction_id, force_success: true }.to_json
  callback_response = http.request(request)

  puts '   ✓ Callback received!'
  callback_data = JSON.parse(callback_response.body)
  puts "   ✓ Callback data: #{callback_data.to_s[0..200]}..."

  puts "\n3. Your webhook endpoint would process this callback and update your DB..."
  status = client.get_status(transaction_id)
  puts "   ✓ Final status: #{status[:transaction][:status]}" if status[:success]
end

def print_menu
  puts "\n#{'=' * 70}"
  puts 'PAYMENT SIMULATOR - DEMO SCENARIOS (Ruby/Sinatra)'
  puts '=' * 70
  puts "\n1. Successful M-Pesa Payment"
  puts '2. Failed M-Pesa Payment (User Cancelled)'
  puts '3. Bank Transfer Payment'
  puts '4. Multiple Payments Dashboard'
  puts '5. Webhook/Callback Integration'
  puts '6. Run All Demos'
  puts '0. Exit'
  puts "\nMake sure the API server is running: ruby app.rb"
  puts '=' * 70
end

# Main loop
if __FILE__ == $PROGRAM_NAME
  loop do
    begin
      print_menu
      print "\nSelect demo scenario (0-6): "
      choice = gets.chomp

      case choice
      when '0'
        puts "\nExiting demo. Goodbye!"
        break
      when '1'
        demo_scenario_1_successful_mpesa
      when '2'
        demo_scenario_2_failed_mpesa
      when '3'
        demo_scenario_3_bank_transfer
      when '4'
        demo_scenario_4_mixed_payments
      when '5'
        demo_scenario_5_webhook_integration
      when '6'
        demo_scenario_1_successful_mpesa
        demo_scenario_2_failed_mpesa
        demo_scenario_3_bank_transfer
        demo_scenario_4_mixed_payments
        demo_scenario_5_webhook_integration
      else
        puts "\n❌ Invalid choice. Please select 0-6."
      end

      puts "\n\nPress Enter to continue..."
      gets
    rescue Interrupt
      puts "\n\nExiting demo. Goodbye!"
      break
    rescue StandardError => e
      puts "\n❌ Error: #{e.message}"
      puts 'Make sure the API server is running!'
      puts "\nPress Enter to continue..."
      gets
    end
  end
end
