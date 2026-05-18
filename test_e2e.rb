# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'

BASE = ENV.fetch('API_BASE', 'http://localhost:3000')
WEBHOOK_BASE = ENV.fetch('WEBHOOK_BASE', 'http://localhost:4567')
API_KEY = ENV['API_KEY']

class E2ERunner
  def initialize
    @passed = 0
    @failed = 0
    @results = []
  end

  def run
    header 'Payment Simulator — Full E2E'
    puts "API: #{BASE}"
    puts "Webhook receiver: #{WEBHOOK_BASE}"
    puts "Auth: #{API_KEY ? 'enabled' : 'disabled'}"
    puts ''

    reset_webhooks
    reset_transactions

    section 'Infrastructure'
    assert_health
    assert_unauthorized_without_key if API_KEY

    section 'Validation & errors'
    assert_mpesa_missing_fields
    assert_transaction_not_found

    section 'M-Pesa — manual callback (happy path)'
    assert_mpesa_manual_success

    section 'M-Pesa — manual callback (failure path)'
    assert_mpesa_manual_failure

    section 'M-Pesa — auto-complete'
    assert_mpesa_auto_success
    assert_mpesa_auto_failure

    section 'Bank transfer — manual completion'
    assert_bank_manual_success
    assert_bank_manual_failure

    section 'Bank transfer — auto-complete'
    assert_bank_auto_success
    assert_bank_auto_failure

    section 'Webhooks'
    reset_webhooks
    assert_mpesa_webhook_success
    assert_mpesa_webhook_failure
    assert_bank_webhook_success
    assert_bank_webhook_failure

    section 'Listing'
    assert_list_payments

    summary
    exit(@failed.positive? ? 1 : 0)
  end

  private

  def section(title)
    puts "\n#{'─' * 60}"
    puts title
    puts '─' * 60
  end

  def header(title)
    puts "\n#{'=' * 60}"
    puts title
    puts '=' * 60
  end

  def pass(name, detail = nil)
    @passed += 1
    @results << [:pass, name, detail]
    puts "  ✓ #{name}#{detail ? " — #{detail}" : ''}"
  end

  def fail(name, detail = nil)
    @failed += 1
    @results << [:fail, name, detail]
    puts "  ✗ #{name}#{detail ? " — #{detail}" : ''}"
  end

  def summary
    header 'Summary'
    total = @passed + @failed
    puts "  Passed: #{@passed}/#{total}"
    puts "  Failed: #{@failed}/#{total}"
    puts ''
    if @failed.positive?
      puts '  Failed cases:'
      @results.select { |r| r[0] == :fail }.each { |_, name, detail| puts "    - #{name}: #{detail}" }
    else
      puts '  All E2E scenarios passed.'
    end
    puts ''
  end

  def http_request(method, path, body: nil)
    uri = URI("#{BASE}#{path}")
    http = Net::HTTP.new(uri.host, uri.port)
    req_class = Net::HTTP.const_get(method.capitalize)
    req = req_class.new(uri)
    req['Content-Type'] = 'application/json'
    req['Authorization'] = "Bearer #{API_KEY}" if API_KEY
    req.body = body.to_json if body
    response = http.request(req)
    parsed = response.body.to_s.empty? ? {} : JSON.parse(response.body, symbolize_names: true)
    [response.code.to_i, parsed]
  end

  def get(path)
    http_request('Get', path)
  end

  def post(path, body)
    http_request('Post', path, body: body)
  end

  def reset_webhooks
    uri = URI("#{WEBHOOK_BASE}/webhooks/clear")
    Net::HTTP.post(uri, '{}', 'Content-Type' => 'application/json')
  rescue Errno::ECONNREFUSED
    fail('Webhook receiver reachable', 'start with: ruby webhook_receiver.rb')
    summary
    exit 1
  end

  def reset_transactions
    code, = post('/api/payments/reset', {})
    pass('Reset transactions', "HTTP #{code}") if code == 200
  end

  def fetch_webhooks
    uri = URI("#{WEBHOOK_BASE}/webhooks")
    JSON.parse(Net::HTTP.get(uri), symbolize_names: true)
  end

  def poll_timeout
    ENV.fetch('CI_POLL_TIMEOUT', '10').to_i
  end

  def wait_for_transaction_status(txn_id, expected_status)
    poll_timeout.times do
      _, status = get("/api/payments/#{txn_id}")
      current = status.dig(:transaction, :status)
      return status if current == expected_status

      sleep 1
    end
    get("/api/payments/#{txn_id}")[1]
  end

  def wait_for_webhook_delivery(txn_id)
    poll_timeout.times do
      _, status = get("/api/payments/#{txn_id}")
      txn = status[:transaction]
      return status if txn&.dig(:webhook_sent)

      sleep 1
    end
    get("/api/payments/#{txn_id}")[1]
  end

  def wait_for_webhook
    poll_timeout.times do
      webhooks = fetch_webhooks
      match = webhooks[:webhooks]&.find { |w| yield(w) }
      return match if match

      sleep 1
    end
    nil
  end

  def assert_health
    code, body = get('/api/health')
    if code == 200 && body[:status] == 'healthy'
      pass('Health check', body[:service])
    else
      fail('Health check', "HTTP #{code} #{body}")
    end
  end

  def assert_unauthorized_without_key
    uri = URI("#{BASE}/api/payments/mpesa/stk-push")
    http = Net::HTTP.new(uri.host, uri.port)
    req = Net::HTTP::Post.new(uri)
    req['Content-Type'] = 'application/json'
    req.body = { phone_number: '254712345678', amount: 100 }.to_json
    code = http.request(req).code.to_i
    code == 401 ? pass('Rejects unauthenticated request', 'HTTP 401') : fail('Rejects unauthenticated request', "HTTP #{code}")
  end

  def assert_mpesa_missing_fields
    code, body = post('/api/payments/mpesa/stk-push', { phone_number: '254712345678' })
    code == 400 && body[:success] == false ? pass('M-Pesa rejects missing amount', 'HTTP 400') : fail('M-Pesa rejects missing amount', "HTTP #{code}")
  end

  def assert_transaction_not_found
    code, = get('/api/payments/MPXNONEXISTENT99')
    code == 404 ? pass('Unknown transaction returns 404') : fail('Unknown transaction returns 404', "HTTP #{code}")
  end

  def assert_mpesa_manual_success
    code, body = post('/api/payments/mpesa/stk-push', {
      phone_number: '254712345678', amount: 500, account_reference: 'E2E-OK',
      auto_complete: false
    })
    return fail('M-Pesa initiate (manual)', "HTTP #{code}") unless code == 200 && body[:success]

    txn_id = body[:transaction_id]
    code, = get("/api/payments/#{txn_id}")
    return fail('M-Pesa pending before callback', "HTTP #{code}") unless code == 200

    code, cb = post('/api/payments/mpesa/callback', { transaction_id: txn_id, force_success: true })
    return fail('M-Pesa success callback', "HTTP #{code}") unless code == 200 && cb.dig(:Body, :stkCallback, :ResultCode) == 0

    _, status = get("/api/payments/#{txn_id}")
    if status.dig(:transaction, :status) == 'completed'
      pass('M-Pesa manual success flow', "receipt #{status.dig(:transaction, :mpesa_receipt)}")
    else
      fail('M-Pesa manual success flow', "status=#{status.dig(:transaction, :status)}")
    end
  end

  def assert_mpesa_manual_failure
    _, body = post('/api/payments/mpesa/stk-push', {
      phone_number: '254798765432', amount: 250, auto_complete: false
    })
    txn_id = body[:transaction_id]

    _, cb = post('/api/payments/mpesa/callback', { transaction_id: txn_id, force_success: false })
    result_code = cb.dig(:Body, :stkCallback, :ResultCode)
    _, status = get("/api/payments/#{txn_id}")

    if result_code == 1032 && status.dig(:transaction, :status) == 'failed'
      pass('M-Pesa manual failure flow', 'result_code 1032')
    else
      fail('M-Pesa manual failure flow', "code=#{result_code} status=#{status.dig(:transaction, :status)}")
    end
  end

  def assert_mpesa_auto_success
    _, body = post('/api/payments/mpesa/stk-push', {
      phone_number: '254711111111', amount: 100, auto_complete: true, force_success: true
    })
    txn_id = body[:transaction_id]
    status = wait_for_transaction_status(txn_id, 'completed')
    status.dig(:transaction, :status) == 'completed' ? pass('M-Pesa auto-complete success') : fail('M-Pesa auto-complete success', status.dig(:transaction, :status).to_s)
  end

  def assert_mpesa_auto_failure
    _, body = post('/api/payments/mpesa/stk-push', {
      phone_number: '254722222222', amount: 100, auto_complete: true, force_success: false
    })
    txn_id = body[:transaction_id]
    status = wait_for_transaction_status(txn_id, 'failed')
    status.dig(:transaction, :status) == 'failed' ? pass('M-Pesa auto-complete failure') : fail('M-Pesa auto-complete failure', status.dig(:transaction, :status).to_s)
  end

  def assert_bank_manual_success
    _, body = post('/api/payments/bank-transfer', {
      account_number: '1234567890', bank_code: '01', amount: 5000,
      reference: 'E2E-BANK-OK', auto_complete: false
    })
    txn_id = body[:transaction_id]

    _, result = post('/api/payments/bank-transfer/complete', { transaction_id: txn_id, force_success: true })
    _, status = get("/api/payments/#{txn_id}")

    if result[:status] == 'completed' && status.dig(:transaction, :status) == 'completed'
      pass('Bank manual success flow', result[:bank_reference])
    else
      fail('Bank manual success flow', result[:status])
    end
  end

  def assert_bank_manual_failure
    _, body = post('/api/payments/bank-transfer', {
      account_number: '9876543210', bank_code: '02', amount: 1000, auto_complete: false
    })
    txn_id = body[:transaction_id]

    _, result = post('/api/payments/bank-transfer/complete', { transaction_id: txn_id, force_success: false })
    _, status = get("/api/payments/#{txn_id}")

    if result[:success] == false && status.dig(:transaction, :status) == 'failed'
      pass('Bank manual failure flow', result[:message])
    else
      fail('Bank manual failure flow', result[:status])
    end
  end

  def assert_bank_auto_success
    _, body = post('/api/payments/bank-transfer', {
      account_number: '1111111111', bank_code: '01', amount: 2000,
      auto_complete: true, force_success: true
    })
    txn_id = body[:transaction_id]
    status = wait_for_transaction_status(txn_id, 'completed')
    status.dig(:transaction, :status) == 'completed' ? pass('Bank auto-complete success') : fail('Bank auto-complete success', status.dig(:transaction, :status).to_s)
  end

  def assert_bank_auto_failure
    _, body = post('/api/payments/bank-transfer', {
      account_number: '2222222222', bank_code: '01', amount: 2000,
      auto_complete: true, force_success: false
    })
    txn_id = body[:transaction_id]
    status = wait_for_transaction_status(txn_id, 'failed')
    status.dig(:transaction, :status) == 'failed' ? pass('Bank auto-complete failure') : fail('Bank auto-complete failure', status.dig(:transaction, :status).to_s)
  end

  def assert_mpesa_webhook_success
    _, body = post('/api/payments/mpesa/stk-push', {
      phone_number: '254733333333', amount: 1500,
      callback_url: "#{WEBHOOK_BASE}/webhooks/mpesa",
      auto_complete: true, force_success: true
    })
    txn_id = body[:transaction_id]
    checkout_id = body[:checkout_request_id]
    wait_for_transaction_status(txn_id, 'completed')
    status = wait_for_webhook_delivery(txn_id)
    mpesa_wh = wait_for_webhook do |w|
      w[:type] == 'mpesa' &&
        w.dig(:payload, :Body, :stkCallback, :CheckoutRequestID) == checkout_id &&
        w.dig(:payload, :Body, :stkCallback, :ResultCode) == 0
    end

    if status.dig(:transaction, :webhook_sent) && status.dig(:transaction, :webhook_result, :success) && mpesa_wh
      pass('M-Pesa webhook success delivery')
    else
      fail(
        'M-Pesa webhook success delivery',
        "webhook_sent=#{status.dig(:transaction, :webhook_sent)} delivered=#{status.dig(:transaction, :webhook_result, :success)}"
      )
    end
  end

  def assert_mpesa_webhook_failure
    _, body = post('/api/payments/mpesa/stk-push', {
      phone_number: '254744444444', amount: 800,
      callback_url: "#{WEBHOOK_BASE}/webhooks/mpesa",
      auto_complete: true, force_success: false
    })
    txn_id = body[:transaction_id]
    checkout_id = body[:checkout_request_id]
    wait_for_transaction_status(txn_id, 'failed')
    wait_for_webhook_delivery(txn_id)
    failed_wh = wait_for_webhook do |w|
      w[:type] == 'mpesa' &&
        w.dig(:payload, :Body, :stkCallback, :CheckoutRequestID) == checkout_id &&
        w.dig(:payload, :Body, :stkCallback, :ResultCode) == 1032
    end

    failed_wh ? pass('M-Pesa webhook failure delivery', 'result_code 1032') : fail('M-Pesa webhook failure delivery')
  end

  def assert_bank_webhook_success
    _, body = post('/api/payments/bank-transfer', {
      account_number: '3333333333', bank_code: '01', amount: 9000,
      callback_url: "#{WEBHOOK_BASE}/webhooks/bank",
      auto_complete: true, force_success: true
    })
    txn_id = body[:transaction_id]
    wait_for_transaction_status(txn_id, 'completed')
    status = wait_for_webhook_delivery(txn_id)
    bank_wh = wait_for_webhook do |w|
      w[:type] == 'bank' && w.dig(:payload, :transaction_id) == txn_id && w.dig(:payload, :status) == 'completed'
    end

    if status.dig(:transaction, :webhook_sent) && bank_wh
      pass('Bank webhook success delivery')
    else
      fail('Bank webhook success delivery')
    end
  end

  def assert_bank_webhook_failure
    _, body = post('/api/payments/bank-transfer', {
      account_number: '4444444444', bank_code: '01', amount: 500,
      callback_url: "#{WEBHOOK_BASE}/webhooks/bank",
      auto_complete: true, force_success: false
    })
    txn_id = body[:transaction_id]
    wait_for_transaction_status(txn_id, 'failed')
    wait_for_webhook_delivery(txn_id)
    bank_wh = wait_for_webhook do |w|
      w[:type] == 'bank' && w.dig(:payload, :transaction_id) == txn_id && w.dig(:payload, :status) == 'failed'
    end

    bank_wh ? pass('Bank webhook failure delivery') : fail('Bank webhook failure delivery')
  end

  def assert_list_payments
    code, body = get('/api/payments')
    if code == 200 && body[:success] && body[:count].to_i >= 8
      pass('List payments', "#{body[:count]} transactions")
    else
      fail('List payments', "count=#{body[:count]}")
    end
  end
end

E2ERunner.new.run
