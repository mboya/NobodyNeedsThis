# Payment Simulator

A fake payment API for when you want to test M-Pesa and bank transfers without real M-Pesa, sandbox access, or patience.

Basically: it pretends to be a payment provider. You give it a phone number and amount, it gives you a transaction ID. Eventually it sends a webhook. Sometimes it succeeds. Sometimes it fails. You can configure this. The default is 95% success—because chaos is a feature, but not *that* much chaos.

**⚠️ Built for:** demos, local dev, testing webhooks before you go live. **Not production. Never production.**

**📖 Live API docs:** [https://nobody-needs-this.vercel.app/docs](https://nobody-needs-this.vercel.app/docs) — interactive reference, curl examples, and one-click API key generation.

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

### API keys (public demo / production)

On the hosted instance you don't need a shared `API_KEY` env var. Generate your own key:

```bash
curl -X POST https://nobody-needs-this.vercel.app/api/keys \
  -H "Content-Type: application/json" \
  -d '{}'
```

Save the `api_key` from the response (shown once). Use it on every request:

```bash
curl -H "Authorization: Bearer ps_live_…" …
```

Or open the [live docs](https://nobody-needs-this.vercel.app/docs) and click **Generate API key**.

**Vercel deployers:** add [Upstash Redis](https://upstash.com) REST credentials so keys persist across serverless instances:

- `UPSTASH_REDIS_REST_URL`
- `UPSTASH_REDIS_REST_TOKEN`

Set `ENABLE_API_KEY_REGISTRATION=false` and `API_KEY=…` if you prefer a single shared key (private installs).

---

## What It Does (That You'll Probably Never Use)

| Thing | Status |
|-------|--------|
| M-Pesa STK Push | ✓ Fake but convincing |
| Bank transfers | ✓ Fake but convincing |
| PesaLink (STA / STP) | ✓ Fake but convincing |
| Webhooks | ✓ POSTs to your URL so you can pretend you're in prod |
| Success/failure | ✓ Force it or leave it to RNG (default 95% success) |
| Transaction IDs & receipts | ✓ Looks real, isn't |

---

## API Reference

| Method | Endpoint | What it does |
|--------|----------|--------------|
| GET | `/api/health` | Are you alive? |
| POST | `/api/keys` | Create your API key (public when registration enabled) |
| DELETE | `/api/keys` | Revoke the key you're using |
| POST | `/api/payments/mpesa/stk-push` | Start M-Pesa flow |
| POST | `/api/payments/mpesa/callback` | Manually trigger callback |
| POST | `/api/payments/bank-transfer` | Start bank transfer |
| POST | `/api/payments/bank-transfer/complete` | Manually complete transfer |
| POST | `/api/payments/pesalink/name-inquiry` | Lookup a fake beneficiary |
| POST | `/api/payments/pesalink/send` | Start a PesaLink transfer |
| POST | `/api/payments/pesalink/complete` | Manually complete (use this on Vercel) |
| GET | `/api/payments/pesalink/banks` | Illustrative sort codes |
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

### PesaLink

Kenya's interbank instant rail, minus the actual IPSL. Name inquiry is deterministic (same account always yields the same fake name). Accounts ending in `00` are not found. Phones with an even last digit are not linked. Amounts outside KES 10–999,999 get code `61`.

Retries: send `Idempotency-Key` (or `idempotency_key` in the body). A non-default `reference` also keys the transfer. Same payload returns the original `PSL…` id (`idempotent_replay: true`). A different payload with that key returns 409 / `94`. Default `reference: TEST` is not a key — those always create a new transfer.

On Vercel, skip `auto_complete` and hit `/complete` yourself — background threads do not survive the response.

```bash
curl -X POST http://localhost:3000/api/payments/pesalink/send \
  -H "Content-Type: application/json" \
  -d '{
    "bank_code": "68",
    "account_number": "0123456789",
    "amount": 500,
    "auto_complete": false
  }'
```

| Param | Required | Notes |
|-------|----------|-------|
| `type` | No | `account` (STA, default) or `phone` (STP) |
| `bank_code` + `account_number` | STA | Illustrative sort codes from `GET /api/payments/pesalink/banks` |
| `phone_number` | STP | Odd last digit = linked |
| `amount` | Yes | KES 10–999,999 |
| `reference` | No | Default `TEST` (no dedupe). Any other value is an idempotency key |
| `idempotency_key` | No | Or `Idempotency-Key` header. Retry returns original `PSL…`; mismatch → 409 |
| `callback_url` | No | Webhook on completion |
| `auto_complete` | No | Default true (~2s). Unreliable on Vercel — use `/complete` |
| `force_outcome` | No | `success` / `insufficient_funds` / `issuer_unavailable` / `invalid_account` / `duplicate` |

---

## Webhooks

Include `callback_url` in your request. When the payment completes (or fails), we POST the callback to that URL. Same shape as real M-Pesa / bank providers. Local receiver paths: `/webhooks/mpesa`, `/webhooks/bank`, `/webhooks/pesalink`.

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
