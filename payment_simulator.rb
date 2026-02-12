# frozen_string_literal: true

require 'securerandom'
require 'json'
require 'time'

# Payment Simulator for Demo/Testing Environments
# Supports M-Pesa and Bank Transfer simulations
module PaymentSimulator
  class PaymentMethod
    MPESA = 'mpesa'
    BANK_TRANSFER = 'bank_transfer'
  end
  
  class PaymentStatus
    PENDING = 'pending'
    PROCESSING = 'processing'
    COMPLETED = 'completed'
    FAILED = 'failed'
    CANCELLED = 'cancelled'
  end
  
  class Simulator
    attr_accessor :success_rate, :enable_delays, :transactions
    
    def initialize(success_rate: 0.95, enable_delays: true)
      @success_rate = success_rate
      @enable_delays = enable_delays
      @transactions = {}
    end
    
    # Send webhook callback to URL
    def send_webhook(url, payload)
      require 'net/http'
      require 'json'
      
      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == 'https')
      http.read_timeout = 10
      
      request = Net::HTTP::Post.new(uri.path, 'Content-Type' => 'application/json')
      request.body = payload.to_json
      
      response = http.request(request)
      
      {
        success: response.is_a?(Net::HTTPSuccess),
        status_code: response.code.to_i,
        response_body: response.body
      }
    rescue StandardError => e
      {
        success: false,
        error: e.message
      }
    end
    
    # Initiate M-Pesa STK Push
    def initiate_mpesa_payment(phone_number:, amount:, account_reference: 'TEST', description: 'Payment', callback_url: nil)
      transaction_id = generate_transaction_id('MPX')
      checkout_request_id = generate_checkout_id
      
      transaction = {
        transaction_id: transaction_id,
        checkout_request_id: checkout_request_id,
        method: PaymentMethod::MPESA,
        phone_number: phone_number,
        amount: amount,
        account_reference: account_reference,
        description: description,
        status: PaymentStatus::PENDING,
        initiated_at: Time.now.iso8601,
        mpesa_receipt: nil,
        result_code: nil,
        result_description: nil,
        callback_url: callback_url
      }
      
      @transactions[transaction_id] = transaction
      
      {
        success: true,
        message: 'STK Push initiated successfully',
        transaction_id: transaction_id,
        checkout_request_id: checkout_request_id,
        status: PaymentStatus::PENDING
      }
    end
    
    # Simulate M-Pesa payment callback
    def simulate_mpesa_callback(transaction_id, force_success: nil)
      return { success: false, message: 'Transaction not found' } unless @transactions.key?(transaction_id)
      
      transaction = @transactions[transaction_id]
      
      # Determine if payment succeeds
      is_successful = force_success.nil? ? (rand < @success_rate) : force_success
      
      if is_successful
        mpesa_receipt = generate_mpesa_receipt
        transaction[:status] = PaymentStatus::COMPLETED
        transaction[:mpesa_receipt] = mpesa_receipt
        transaction[:result_code] = 0
        transaction[:result_description] = 'The service request is processed successfully'
        transaction[:completed_at] = Time.now.iso8601
        
        callback = {
          Body: {
            stkCallback: {
              MerchantRequestID: transaction[:checkout_request_id],
              CheckoutRequestID: transaction[:checkout_request_id],
              ResultCode: 0,
              ResultDesc: 'The service request is processed successfully',
              CallbackMetadata: {
                Item: [
                  { Name: 'Amount', Value: transaction[:amount] },
                  { Name: 'MpesaReceiptNumber', Value: mpesa_receipt },
                  { Name: 'TransactionDate', Value: Time.now.strftime('%Y%m%d%H%M%S') },
                  { Name: 'PhoneNumber', Value: transaction[:phone_number] }
                ]
              }
            }
          }
        }
      else
        transaction[:status] = PaymentStatus::FAILED
        transaction[:result_code] = 1032
        transaction[:result_description] = 'Request cancelled by user'
        transaction[:completed_at] = Time.now.iso8601
        
        callback = {
          Body: {
            stkCallback: {
              MerchantRequestID: transaction[:checkout_request_id],
              CheckoutRequestID: transaction[:checkout_request_id],
              ResultCode: 1032,
              ResultDesc: 'Request cancelled by user'
            }
          }
        }
      end
      
      # Send webhook if callback_url is provided
      if transaction[:callback_url]
        webhook_result = send_webhook(transaction[:callback_url], callback)
        transaction[:webhook_sent] = true
        transaction[:webhook_result] = webhook_result
      end
      
      callback
    end
    
    # Initiate bank transfer
    def initiate_bank_transfer(account_number:, bank_code:, amount:, reference: 'TEST', narration: 'Payment', callback_url: nil)
      transaction_id = generate_transaction_id('BNK')
      
      transaction = {
        transaction_id: transaction_id,
        method: PaymentMethod::BANK_TRANSFER,
        account_number: account_number,
        bank_code: bank_code,
        amount: amount,
        reference: reference,
        narration: narration,
        status: PaymentStatus::PROCESSING,
        initiated_at: Time.now.iso8601,
        bank_reference: nil,
        callback_url: callback_url
      }
      
      @transactions[transaction_id] = transaction
      
      {
        success: true,
        message: 'Bank transfer initiated successfully',
        transaction_id: transaction_id,
        status: PaymentStatus::PROCESSING
      }
    end
    
    # Simulate bank transfer completion
    def simulate_bank_transfer_completion(transaction_id, force_success: nil)
      return { success: false, message: 'Transaction not found' } unless @transactions.key?(transaction_id)
      
      transaction = @transactions[transaction_id]
      
      # Determine if transfer succeeds
      is_successful = force_success.nil? ? (rand < @success_rate) : force_success
      
      if is_successful
        bank_reference = generate_bank_reference
        transaction[:status] = PaymentStatus::COMPLETED
        transaction[:bank_reference] = bank_reference
        transaction[:completed_at] = Time.now.iso8601
        
        result = {
          success: true,
          transaction_id: transaction_id,
          status: PaymentStatus::COMPLETED,
          bank_reference: bank_reference,
          message: 'Transfer completed successfully',
          account_number: transaction[:account_number],
          amount: transaction[:amount],
          reference: transaction[:reference]
        }
      else
        transaction[:status] = PaymentStatus::FAILED
        transaction[:failure_reason] = 'Insufficient funds'
        transaction[:completed_at] = Time.now.iso8601
        
        result = {
          success: false,
          transaction_id: transaction_id,
          status: PaymentStatus::FAILED,
          message: 'Transfer failed: Insufficient funds',
          account_number: transaction[:account_number],
          amount: transaction[:amount],
          reference: transaction[:reference]
        }
      end
      
      # Send webhook if callback_url is provided
      if transaction[:callback_url]
        webhook_result = send_webhook(transaction[:callback_url], result)
        transaction[:webhook_sent] = true
        transaction[:webhook_result] = webhook_result
      end
      
      result
    end
    
    # Get transaction status
    def get_transaction_status(transaction_id)
      return { success: false, message: 'Transaction not found' } unless @transactions.key?(transaction_id)
      
      {
        success: true,
        transaction: @transactions[transaction_id]
      }
    end
    
    # List all transactions with optional filtering
    def list_transactions(status: nil, method: nil)
      transactions = @transactions.values
      
      transactions = transactions.select { |t| t[:status] == status } if status
      transactions = transactions.select { |t| t[:method] == method } if method
      
      {
        success: true,
        count: transactions.length,
        transactions: transactions
      }
    end
    
    # Clear all transactions
    def reset_transactions
      @transactions = {}
      { success: true, message: 'All transactions cleared' }
    end
    
    private
    
    # Generate unique transaction ID
    def generate_transaction_id(prefix)
      "#{prefix}#{SecureRandom.hex(6).upcase}"
    end
    
    # Generate M-Pesa checkout request ID
    def generate_checkout_id
      "ws_CO_#{Time.now.strftime('%Y%m%d%H%M%S')}_#{rand(100_000..999_999)}"
    end
    
    # Generate M-Pesa receipt number
    def generate_mpesa_receipt
      "#{('A'..'Z').to_a.sample(2).join}#{rand(10_000_000..99_999_999)}"
    end
    
    # Generate bank reference number
    def generate_bank_reference
      "FT#{Time.now.strftime('%y%m%d')}#{rand(100_000..999_999)}"
    end
  end
end

# Example usage
if __FILE__ == $PROGRAM_NAME
  simulator = PaymentSimulator::Simulator.new(success_rate: 0.9)
  
  puts '=' * 60
  puts 'PAYMENT SIMULATOR - DEMO MODE'
  puts '=' * 60
  
  # Test M-Pesa payment
  puts "\n1. Initiating M-Pesa payment..."
  mpesa_response = simulator.initiate_mpesa_payment(
    phone_number: '254712345678',
    amount: 1000.00,
    account_reference: 'ORD-12345',
    description: 'Test Order Payment'
  )
  puts "Response: #{mpesa_response}"
  
  puts "\n2. Simulating M-Pesa callback (user entered PIN)..."
  callback = simulator.simulate_mpesa_callback(mpesa_response[:transaction_id])
  puts "Callback: #{callback}"
  
  puts "\n3. Checking M-Pesa transaction status..."
  status = simulator.get_transaction_status(mpesa_response[:transaction_id])
  puts "Status: #{status}"
  
  # Test Bank Transfer
  puts "\n#{'=' * 60}"
  puts "\n4. Initiating Bank transfer..."
  bank_response = simulator.initiate_bank_transfer(
    account_number: '1234567890',
    bank_code: '01',
    amount: 5000.00,
    reference: 'INV-67890',
    narration: 'Supplier Payment'
  )
  puts "Response: #{bank_response}"
  
  puts "\n5. Simulating Bank transfer completion..."
  completion = simulator.simulate_bank_transfer_completion(bank_response[:transaction_id])
  puts "Completion: #{completion}"
  
  puts "\n6. Checking Bank transfer status..."
  status = simulator.get_transaction_status(bank_response[:transaction_id])
  puts "Status: #{status}"
  
  # List all transactions
  puts "\n#{'=' * 60}"
  puts "\n7. Listing all transactions..."
  all_transactions = simulator.list_transactions
  puts "Total transactions: #{all_transactions[:count]}"
  all_transactions[:transactions].each do |txn|
    puts "  - #{txn[:transaction_id]}: #{txn[:method]} - #{txn[:status]}"
  end
end