# frozen_string_literal: true

require 'digest'
require 'json'
require 'time'
require_relative '../payment_simulator'

module PaymentSimulator
  # Fake PesaLink (IPSL) instant credit transfer rail.
  # Included into PaymentSimulator::Simulator — reuses @transactions,
  # @success_rate, generate_transaction_id, and send_webhook.
  module Pesalink
    METHOD = 'pesalink'

    # Illustrative Kenyan sort codes — NOT the official IPSL participant list.
    BANKS = {
      '01' => 'KCB Bank Kenya',
      '02' => 'Standard Chartered Bank Kenya',
      '03' => 'Absa Bank Kenya',
      '07' => 'NCBA Bank Kenya',
      '11' => 'Co-operative Bank of Kenya',
      '31' => 'Stanbic Bank Kenya',
      '57' => 'I&M Bank Kenya',
      '63' => 'Diamond Trust Bank Kenya',
      '68' => 'Equity Bank Kenya',
      '70' => 'Family Bank'
    }.freeze

    FIRST_NAMES = %w[Wanjiku Otieno Achieng Kamau Nyambura Mutiso Wambui Kariuki Amina Chebet].freeze
    LAST_NAMES = %w[Mwangi Omondi Njoroge Wekesa Hassan Kimani Cheruiyot Odhiambo Atieno Kiprop].freeze

    # ISO 8583-style response codes used by this fake switch.
    OUTCOMES = {
      'success' => { code: '00', message: 'Approved', reversed: false, status: PaymentStatus::COMPLETED },
      'insufficient_funds' => { code: '51', message: 'Insufficient funds', reversed: false, status: PaymentStatus::FAILED },
      'issuer_unavailable' => { code: '91', message: 'Receiving bank timeout', reversed: true, status: PaymentStatus::FAILED },
      'invalid_account' => { code: '14', message: 'Invalid account number', reversed: false, status: PaymentStatus::FAILED },
      'duplicate' => { code: '94', message: 'Duplicate transmission', reversed: false, status: PaymentStatus::FAILED }
    }.freeze

    OUTCOME_ALIASES = {
      '00' => 'success',
      '51' => 'insufficient_funds',
      '91' => 'issuer_unavailable',
      '14' => 'invalid_account',
      '94' => 'duplicate'
    }.freeze

    DEFAULT_MIN_AMOUNT = 10.0
    DEFAULT_MAX_AMOUNT = 999_999.0
    DEFAULT_FAILURE_WEIGHTS = {
      'insufficient_funds' => 50,
      'issuer_unavailable' => 25,
      'invalid_account' => 15,
      'duplicate' => 10
    }.freeze

    def pesalink_min_amount
      @pesalink_min_amount || DEFAULT_MIN_AMOUNT
    end

    def pesalink_max_amount
      @pesalink_max_amount || DEFAULT_MAX_AMOUNT
    end

    def pesalink_failure_weights
      @pesalink_failure_weights || DEFAULT_FAILURE_WEIGHTS
    end

    attr_writer :pesalink_min_amount, :pesalink_max_amount, :pesalink_failure_weights

    # Beneficiary lookup. Deterministic names from bank_code+account_number.
    # Sentinels (documented for tests):
    #   - account numbers ending in "00" → code 14, not found
    #   - phone whose last digit is even → not linked (STP)
    def pesalink_name_inquiry(bank_code: nil, account_number: nil, phone_number: nil)
      if present?(phone_number) && !present?(account_number)
        return stp_name_inquiry(phone_number)
      end

      unless present?(bank_code) && present?(account_number)
        return {
          success: false,
          found: false,
          response_code: '30',
          message: 'Provide bank_code and account_number, or phone_number'
        }
      end

      sta_name_inquiry(bank_code.to_s, account_number.to_s, phone_number: phone_number)
    end

    def initiate_pesalink_transfer(type: 'account', bank_code: nil, account_number: nil,
                                   phone_number: nil, amount:, reference: 'TEST',
                                   narration: 'Payment', callback_url: nil)
      type = type.to_s.downcase
      unless %w[account phone].include?(type)
        return { success: false, message: "type must be 'account' (STA) or 'phone' (STP)" }
      end

      numeric_amount = amount.to_f
      if numeric_amount < pesalink_min_amount || numeric_amount > pesalink_max_amount
        return {
          success: false,
          response_code: '61',
          message: "Amount exceeds PesaLink limit (KES #{format_kes(pesalink_min_amount)}–#{format_kes(pesalink_max_amount)})"
        }
      end

      inquiry = if type == 'phone'
                  pesalink_name_inquiry(phone_number: phone_number)
                else
                  pesalink_name_inquiry(bank_code: bank_code, account_number: account_number)
                end

      unless inquiry[:success]
        return {
          success: false,
          response_code: inquiry[:response_code] || '14',
          message: inquiry[:message] || 'Beneficiary not found'
        }
      end

      transaction_id = generate_transaction_id('PSL')
      transaction = {
        transaction_id: transaction_id,
        method: METHOD,
        type: type,
        bank_code: inquiry[:bank_code],
        bank_name: inquiry[:bank_name],
        account_number: inquiry[:account_number],
        phone_number: inquiry[:phone_number],
        beneficiary_name: inquiry[:account_name],
        amount: numeric_amount,
        reference: reference,
        narration: narration,
        status: PaymentStatus::PROCESSING,
        initiated_at: Time.now.iso8601,
        response_code: nil,
        rrn: nil,
        reversed: false,
        callback_url: callback_url
      }

      @transactions[transaction_id] = transaction

      {
        success: true,
        message: 'PesaLink transfer initiated',
        transaction_id: transaction_id,
        status: PaymentStatus::PROCESSING,
        type: type,
        bank_code: inquiry[:bank_code],
        bank_name: inquiry[:bank_name],
        account_number: inquiry[:account_number],
        beneficiary_name: inquiry[:account_name],
        amount: numeric_amount
      }
    end

    def simulate_pesalink_completion(transaction_id, force_outcome: nil)
      return { success: false, message: 'Transaction not found' } unless @transactions.key?(transaction_id)

      transaction = @transactions[transaction_id]
      unless transaction[:method] == METHOD
        return { success: false, message: 'Transaction is not a PesaLink transfer' }
      end

      if %w[completed failed].include?(transaction[:status])
        return duplicate_result(transaction)
      end

      outcome_key = resolve_pesalink_outcome(force_outcome)
      spec = OUTCOMES.fetch(outcome_key)

      transaction[:status] = spec[:status]
      transaction[:response_code] = spec[:code]
      transaction[:result_description] = spec[:message]
      transaction[:reversed] = spec[:reversed]
      transaction[:completed_at] = Time.now.iso8601
      transaction[:rrn] = generate_pesalink_rrn if outcome_key == 'success'

      result = pesalink_completion_payload(transaction, spec)

      if transaction[:callback_url]
        webhook_result = send_webhook(transaction[:callback_url], result)
        transaction[:webhook_sent] = true
        transaction[:webhook_result] = webhook_result
      end

      result
    end

    def pesalink_banks
      BANKS.map { |code, name| { code: code, name: name } }
    end

    private

    def present?(value)
      !value.to_s.strip.empty?
    end

    def format_kes(value)
      value.to_i.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
    end

    def sta_name_inquiry(bank_code, account_number, phone_number: nil)
      bank_name = BANKS[bank_code]
      unless bank_name
        return {
          success: false,
          found: false,
          response_code: '14',
          message: 'Unknown bank_code'
        }
      end

      # Sentinel: account numbers ending in "00" are not found.
      if account_number.end_with?('00')
        return {
          success: false,
          found: false,
          response_code: '14',
          message: 'Account not found'
        }
      end

      {
        success: true,
        found: true,
        response_code: '00',
        bank_code: bank_code,
        bank_name: bank_name,
        account_number: account_number,
        account_name: fake_account_name(bank_code, account_number),
        phone_number: present?(phone_number) ? phone_number.to_s : nil
      }
    end

    def stp_name_inquiry(phone_number)
      phone = phone_number.to_s.strip
      last_digit = phone[-1].to_i

      # Sentinel: even trailing digit → phone not linked to a bank account.
      if last_digit.even?
        return {
          success: false,
          found: false,
          response_code: '14',
          message: 'Phone number is not linked to a bank account'
        }
      end

      resolved = resolve_phone_to_account(phone)
      sta_name_inquiry(resolved[:bank_code], resolved[:account_number], phone_number: phone)
    end

    def fake_account_name(bank_code, account_number)
      seed = stable_seed("#{bank_code}:#{account_number}")
      first = FIRST_NAMES[seed % FIRST_NAMES.length]
      last = LAST_NAMES[(seed / FIRST_NAMES.length) % LAST_NAMES.length]
      "#{first} #{last}".upcase
    end

    def resolve_phone_to_account(phone_number)
      seed = stable_seed("pesalink-stp:#{phone_number}")
      codes = BANKS.keys
      bank_code = codes[seed % codes.length]
      account = format('%010d', seed % 1_000_000_000)
      account = "#{account[0..-3]}01" if account.end_with?('00')
      { bank_code: bank_code, account_number: account }
    end

    def stable_seed(input)
      Digest::SHA256.hexdigest(input)[0, 8].to_i(16)
    end

    def resolve_pesalink_outcome(force_outcome)
      return pick_pesalink_outcome if force_outcome.nil? || force_outcome.to_s.strip.empty?

      key = force_outcome.to_s
      mapped = OUTCOME_ALIASES[key] || key
      return mapped if OUTCOMES.key?(mapped)

      pick_pesalink_outcome
    end

    def pick_pesalink_outcome
      return 'success' if rand < @success_rate

      weights = pesalink_failure_weights
      total = weights.values.sum.to_f
      roll = rand * total
      cumulative = 0.0
      weights.each do |key, weight|
        cumulative += weight
        return key.to_s if roll < cumulative
      end
      weights.keys.last.to_s
    end

    def generate_pesalink_rrn
      format('%012d', SecureRandom.random_number(10**12))
    end

    def pesalink_completion_payload(transaction, spec)
      {
        success: spec[:code] == '00',
        transaction_id: transaction[:transaction_id],
        status: transaction[:status],
        response_code: spec[:code],
        rrn: transaction[:rrn],
        reversed: transaction[:reversed],
        message: spec[:message],
        amount: transaction[:amount],
        reference: transaction[:reference],
        beneficiary_name: transaction[:beneficiary_name],
        bank_code: transaction[:bank_code],
        account_number: transaction[:account_number]
      }
    end

    def duplicate_result(transaction)
      {
        success: false,
        transaction_id: transaction[:transaction_id],
        status: transaction[:status],
        response_code: '94',
        rrn: transaction[:rrn],
        reversed: transaction[:reversed] == true,
        message: 'Duplicate transmission',
        amount: transaction[:amount],
        reference: transaction[:reference]
      }
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  require_relative '../payment_simulator'
  PaymentSimulator::Simulator.include(PaymentSimulator::Pesalink)

  sim = PaymentSimulator::Simulator.new(success_rate: 1.0)

  puts '=' * 60
  puts 'PESALINK SIMULATOR — DEMO MODE'
  puts '=' * 60

  puts "\n1. Name inquiry (STA, Equity 68)..."
  inquiry = sim.pesalink_name_inquiry(bank_code: '68', account_number: '0123456789')
  puts inquiry

  puts "\n2. Name inquiry miss (account ending 00)..."
  miss = sim.pesalink_name_inquiry(bank_code: '68', account_number: '0123456700')
  puts miss

  puts "\n3. STA transfer + forced success..."
  initiated = sim.initiate_pesalink_transfer(
    type: 'account',
    bank_code: '68',
    account_number: '0123456789',
    amount: 500
  )
  puts initiated
  done = sim.simulate_pesalink_completion(initiated[:transaction_id], force_outcome: 'success')
  puts done

  puts "\n4. Forced issuer_unavailable (91, reversed)..."
  timed_out = sim.initiate_pesalink_transfer(
    type: 'account',
    bank_code: '01',
    account_number: '1111111111',
    amount: 250
  )
  timeout_result = sim.simulate_pesalink_completion(timed_out[:transaction_id], force_outcome: 'issuer_unavailable')
  puts timeout_result

  puts "\n5. Limit rejection (KES 2,000,000)..."
  over = sim.initiate_pesalink_transfer(
    type: 'account',
    bank_code: '68',
    account_number: '0123456789',
    amount: 2_000_000
  )
  puts over
end
