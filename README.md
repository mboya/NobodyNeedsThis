# Payment Simulator

A fake payment API for when you want to test M-Pesa and bank transfers without real M-Pesa, sandbox access, or patience.

Basically: it pretends to be a payment provider. You give it a phone number and amount, it gives you a transaction ID. Eventually it sends a webhook. Sometimes it succeeds. Sometimes it fails. You can configure this. The default is 95% success—because chaos is a feature, but not *that* much chaos.

**⚠️ Built for:** demos, local dev, testing webhooks before you go live. **Not production. Never production.**

---

## Quick Start

```bash
bundle install
ruby app.rb
```

Server runs at `http://localhost:3000`. That's it.

**Try it:**
```bash
curl -X POST http://localhost:3000/api/payments/mpesa/stk-push \
  -H "Content-Type: application/json" \
  -d '{"phone_number": "254712345678", "amount": 1000, "auto_complete": true}'
```

You'll get a transaction ID. Wait ~2 seconds. The callback fires. Magic. (It's not magic, it's just fake money.)

---

## What It Does (That You'll Probably Never Use)

| Thing | Status |
|-------|--------|
| M-Pesa STK Push | ✓ Fake but convincing |
| Bank transfers | ✓ Fake but convincing |
| Webhooks | ✓ POSTs to your URL so you can pretend you're in prod |
| Success/failure | ✓ Force it or leave it to RNG (default 95% success) |
| Transaction IDs & receipts | ✓ Looks real, isn't |

---

## API Reference

| Method | Endpoint | What it does |
|--------|----------|--------------|
| GET | `/api/health` | Are you alive? |
| POST | `/api/payments/mpesa/stk-push` | Start M-Pesa flow |
| POST | `/api/payments/mpesa/callback` | Manually trigger callback |
| POST | `/api/payments/bank-transfer` | Start bank transfer |
| POST | `/api/payments/bank-transfer/complete` | Manually complete transfer |
| GET | `/api/payments/:id` | Check status |
| GET | `/api/payments` | List all (for your dashboard of fake money) |
| POST | `/api/payments/reset` | Nuclear option: clear everything |

### M-Pesa

```bash
curl -X POST http://localhost:3000/api/payments/mpesa/stk-push \
  -H "Content-Type: application/json" \
  -d '{
    "phone_number": "254712345678",
    "amount": 1000,
    "account_reference": "ORDER-123",
    "callback_url": "https://your-app.com/webhooks/mpesa",
    "auto_complete": true,
    "force_success": true
  }'
```

| Param | Required | Notes |
|-------|----------|-------|
| `phone_number` | Yes | 254XXXXXXXXX format |
| `amount` | Yes | Float |
| `account_reference` | No | Defaults to "TEST" |
| `callback_url` | No | Where to POST the callback |
| `auto_complete` | No | `true` = fires callback in ~2s. Default: true |
| `force_success` | No | `true`/`false`/`nil` (random) |

### Bank Transfer

```bash
curl -X POST http://localhost:3000/api/payments/bank-transfer \
  -H "Content-Type: application/json" \
  -d '{
    "account_number": "1234567890",
    "bank_code": "01",
    "amount": 5000,
    "reference": "INV-123",
    "callback_url": "https://your-app.com/webhooks/bank",
    "auto_complete": true
  }'
```

---

## Webhooks

Include `callback_url` in your request. When the payment completes (or fails), we POST the callback to that URL. Same shape as real M-Pesa / bank providers.

### Test webhooks locally

**Terminal 1** – webhook receiver:
```bash
ruby webhook_receiver.rb
# Runs at http://localhost:4567
```

**Terminal 2** – simulator:
```bash
ruby app.rb
```

**Terminal 3** – trigger a payment with a local callback:
```bash
curl -X POST http://localhost:3000/api/payments/mpesa/stk-push \
  -H "Content-Type: application/json" \
  -d '{
    "phone_number": "254712345678",
    "amount": 1000,
    "callback_url": "http://localhost:4567/webhooks/mpesa",
    "auto_complete": true
  }'
```

View received webhooks: `curl http://localhost:4567/webhooks` or hit the URL in a browser.

### M-Pesa callback payload (success)

```json
{
  "Body": {
    "stkCallback": {
      "CheckoutRequestID": "ws_CO_...",
      "ResultCode": 0,
      "ResultDesc": "The service request is processed successfully",
      "CallbackMetadata": {
        "Item": [
          { "Name": "Amount", "Value": 1000.0 },
          { "Name": "MpesaReceiptNumber", "Value": "AB12345678" },
          { "Name": "TransactionDate", "Value": "20240211120500" },
          { "Name": "PhoneNumber", "Value": "254712345678" }
        ]
      }
    }
  }
}
```

### M-Pesa result codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1032 | User cancelled |
| 1037 | Timeout (no PIN) |
| 2001 | Wrong PIN |
| 1 | Insufficient balance |

---

## Direct Ruby usage

When you don't want to hit the API:

```ruby
require_relative 'payment_simulator'

sim = PaymentSimulator::Simulator.new(success_rate: 0.95)

# Start payment
res = sim.initiate_mpesa_payment(
  phone_number: '254712345678',
  amount: 1000,
  account_reference: 'ORDER-123',
  callback_url: 'https://yourapp.com/webhooks/mpesa'
)

# Simulate callback (or let auto_complete do it via API)
sim.simulate_mpesa_callback(res[:transaction_id], force_success: true)

# Check status
sim.get_transaction_status(res[:transaction_id])
```

---

## Rails integration

Point your dev/staging payment service at the simulator:

```ruby
# config/initializers/payment_simulator.rb
PAYMENT_SIMULATOR_URL = ENV.fetch('PAYMENT_SIMULATOR_URL', 'http://localhost:3000')

# app/services/payment_service.rb
class PaymentService
  def initiate_mpesa(phone:, amount:, reference:, callback_url: nil)
    uri = URI("#{PAYMENT_SIMULATOR_URL}/api/payments/mpesa/stk-push")
    response = Net::HTTP.post(
      uri,
      {
        phone_number: phone,
        amount: amount,
        account_reference: reference,
        callback_url: callback_url,
        auto_complete: true
      }.to_json,
      'Content-Type' => 'application/json'
    )
    JSON.parse(response.body, symbolize_names: true)
  end
end
```

Webhook handler (Rails) – same structure as real M-Pesa:

```ruby
# config/routes.rb
post '/webhooks/mpesa', to: 'webhooks#mpesa'

# app/controllers/webhooks_controller.rb
def mpesa
  payload = JSON.parse(request.body.read, symbolize_names: true)
  callback = payload.dig(:Body, :stkCallback)
  result_code = callback[:ResultCode]

  if result_code == 0
    # Success – update order, send confirmation, etc.
  else
    # Failed – update order, notify user
  end

  head :ok  # Always ack quickly
end
```

---

## Config

```ruby
# 95% success (default), 5% "user cancelled"
PaymentSimulator::Simulator.new(success_rate: 0.95)

# Demos: always succeed
PaymentSimulator::Simulator.new(success_rate: 1.0)

# Stress-test failure handling
PaymentSimulator::Simulator.new(success_rate: 0.5)
```

---

## Demos

```bash
ruby demo_scripts.rb
```

Interactive menu: successful M-Pesa, failed M-Pesa, bank transfer, webhook test. Good for screenshots and stakeholder demos.

---

## Project layout

```
.
├── app.rb                 # Sinatra API (the server)
├── payment_simulator.rb   # Core logic (the fake bank)
├── demo_scripts.rb       # Interactive demos
├── webhook_receiver.rb   # Local webhook tester
├── test_webhook.rb       # Webhook tests
└── Gemfile
```

---

## Troubleshooting

**Port 3000 in use?**
```bash
lsof -i :3000
kill $(lsof -t -i:3000)
```

**Transactions not completing?** Check `auto_complete: true`. Callback fires after ~2s for M-Pesa, ~3s for bank transfers.

**Need a clean slate?**
```bash
curl -X POST http://localhost:3000/api/payments/reset
```

**Auto-reload during dev:**
```bash
bundle exec rerun ruby app.rb
```

---

## ⚠️ Important

This is a simulator. For testing. And demos. Not for handling real money.

For production: use real M-Pesa / bank APIs, proper auth, webhook verification, the whole thing. You knew that. Just saying.

---

Built with Ruby + Sinatra. ~20MB RAM, <1s startup. Approximately zero users besides whoever built it. If you're one of the 7 people who need this, enjoy.
