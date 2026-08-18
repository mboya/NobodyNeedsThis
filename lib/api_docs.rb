# frozen_string_literal: true

module ApiDocs
  module_function

  def endpoints
    [
      {
        method: 'GET',
        path: '/api/health',
        title: 'Health check',
        auth: false,
        description: 'Returns service status. No authentication required.',
        response: '{ "status": "healthy", "service": "payment-simulator", "environment": "production", "auth_required": true, "registration_enabled": true, "api_key_store": "redis" }'
      },
      {
        method: 'POST',
        path: '/api/keys',
        title: 'Create API key',
        auth: false,
        description: 'Generate a personal API key (shown once). No auth required when ENABLE_API_KEY_REGISTRATION is true. Rate-limited per IP.',
        body: '{}',
        response: '{ "success": true, "api_key": "ps_live_…", "message": "Save this key now…" }'
      },
      {
        method: 'DELETE',
        path: '/api/keys',
        title: 'Revoke API key',
        auth: true,
        description: 'Revokes the API key sent on this request. Bootstrap/env keys cannot be revoked via this endpoint.',
        body: nil,
        response: '{ "success": true, "message": "API key revoked" }'
      },
      {
        method: 'POST',
        path: '/api/payments/mpesa/stk-push',
        title: 'M-Pesa STK Push',
        auth: true,
        description: 'Initiate a fake M-Pesa STK push. With auto_complete (default true), a callback is simulated after ~2 seconds.',
        body: <<~JSON.strip,
          {
            "phone_number": "254712345678",
            "amount": 1000,
            "account_reference": "ORDER-123",
            "description": "Payment",
            "callback_url": "https://your-app.com/webhooks/mpesa",
            "auto_complete": true,
            "force_success": true
          }
        JSON
        params: [
          ['phone_number', 'yes', '254XXXXXXXXX'],
          ['amount', 'yes', 'Number'],
          ['account_reference', 'no', 'Default: TEST'],
          ['description', 'no', 'Default: Payment'],
          ['callback_url', 'no', 'Webhook URL when payment completes'],
          ['auto_complete', 'no', 'true = simulate callback after ~2s (default true)'],
          ['force_success', 'no', 'true / false / omit for random (~95% success)']
        ]
      },
      {
        method: 'POST',
        path: '/api/payments/mpesa/callback',
        title: 'M-Pesa callback (manual)',
        auth: true,
        description: 'Manually trigger the M-Pesa STK callback for a transaction. Use when auto_complete is false.',
        body: <<~JSON.strip,
          {
            "transaction_id": "MPXABC123",
            "force_success": true
          }
        JSON
        params: [
          ['transaction_id', 'yes', 'From stk-push response'],
          ['force_success', 'no', 'true = success (0), false = cancelled (1032)']
        ]
      },
      {
        method: 'POST',
        path: '/api/payments/bank-transfer',
        title: 'Bank transfer',
        auth: true,
        description: 'Initiate a fake bank transfer. Auto-completes after ~3 seconds when auto_complete is true.',
        body: <<~JSON.strip,
          {
            "account_number": "1234567890",
            "bank_code": "01",
            "amount": 5000,
            "reference": "INV-123",
            "narration": "Supplier payment",
            "callback_url": "https://your-app.com/webhooks/bank",
            "auto_complete": true,
            "force_success": true
          }
        JSON
        params: [
          ['account_number', 'yes', 'Beneficiary account'],
          ['bank_code', 'yes', 'Bank identifier'],
          ['amount', 'yes', 'Number'],
          ['reference', 'no', 'Default: TEST'],
          ['narration', 'no', 'Default: Payment'],
          ['callback_url', 'no', 'Webhook URL on completion'],
          ['auto_complete', 'no', 'Default true'],
          ['force_success', 'no', 'true / false / random']
        ]
      },
      {
        method: 'POST',
        path: '/api/payments/bank-transfer/complete',
        title: 'Bank transfer complete (manual)',
        auth: true,
        description: 'Manually complete a bank transfer when auto_complete is false.',
        body: <<~JSON.strip,
          {
            "transaction_id": "BNKABC123",
            "force_success": true
          }
        JSON
        params: [
          ['transaction_id', 'yes', 'From bank-transfer response'],
          ['force_success', 'no', 'true = completed, false = failed']
        ]
      },
      {
        method: 'POST',
        path: '/api/payments/pesalink/name-inquiry',
        title: 'PesaLink name inquiry',
        auth: true,
        description: 'Resolve a beneficiary before sending. STA: bank_code + account_number. STP: phone_number. Deterministic fake names (same inputs always return the same name). Sentinels: account ending 00 → 14 not found (HTTP 404); phone with even last digit → not linked (HTTP 404).',
        body: <<~JSON.strip,
          {
            "bank_code": "68",
            "account_number": "0123456789"
          }
        JSON
        params: [
          ['bank_code', 'STA', 'Illustrative sort code, e.g. 68 = Equity'],
          ['account_number', 'STA', 'Ends in 00 → not found'],
          ['phone_number', 'STP', 'Even last digit → not linked']
        ],
        response: '{ "success": true, "found": true, "response_code": "00", "bank_code": "68", "bank_name": "Equity Bank Kenya", "account_number": "0123456789", "account_name": "WANJIKU MWANGI" }'
      },
      {
        method: 'POST',
        path: '/api/payments/pesalink/send',
        title: 'PesaLink send',
        auth: true,
        description: 'Initiate a fake IPSL credit transfer. type=account (STA) needs bank_code+account_number; type=phone (STP) needs phone_number. Amounts outside KES 10–999,999 return 422 with code 61. auto_complete (default true) fires a callback after ~2s — unreliable on Vercel; use POST /complete there. force_outcome: success | insufficient_funds | issuer_unavailable | invalid_account | duplicate.',
        body: <<~JSON.strip,
          {
            "type": "account",
            "bank_code": "68",
            "account_number": "0123456789",
            "amount": 500,
            "reference": "INV-123",
            "narration": "Payment",
            "callback_url": "https://your-app.com/webhooks/pesalink",
            "auto_complete": true,
            "force_outcome": "success"
          }
        JSON
        params: [
          ['type', 'no', "account (STA, default) or phone (STP)"],
          ['bank_code', 'STA', 'Required for type=account'],
          ['account_number', 'STA', 'Required for type=account'],
          ['phone_number', 'STP', 'Required for type=phone; odd last digit = linked'],
          ['amount', 'yes', 'KES 10–999,999 or 422 / code 61'],
          ['reference', 'no', 'Default: TEST'],
          ['narration', 'no', 'Default: Payment'],
          ['callback_url', 'no', 'Webhook URL on completion'],
          ['auto_complete', 'no', 'Default true (~2s). On Vercel use /complete instead'],
          ['force_outcome', 'no', 'success | insufficient_funds | issuer_unavailable | invalid_account | duplicate']
        ]
      },
      {
        method: 'POST',
        path: '/api/payments/pesalink/complete',
        title: 'PesaLink complete (manual)',
        auth: true,
        description: 'Manually complete a PesaLink transfer. This is the reliable path on Vercel — background threads die after the HTTP response, so do not depend on auto_complete there. Returns ISO 8583-style codes (00 success + rrn, 51, 91 reversed, 14, 94).',
        body: <<~JSON.strip,
          {
            "transaction_id": "PSLABC123",
            "force_outcome": "success"
          }
        JSON
        params: [
          ['transaction_id', 'yes', 'From /send response'],
          ['force_outcome', 'no', 'Same values as /send']
        ]
      },
      {
        method: 'GET',
        path: '/api/payments/pesalink/banks',
        title: 'PesaLink banks',
        auth: true,
        description: 'Illustrative Kenyan sort codes used by this fake switch. Not the official IPSL participant list.',
        response: '{ "success": true, "note": "Illustrative sort codes, not the official IPSL participant list.", "banks": [{ "code": "01", "name": "KCB Bank Kenya" }, { "code": "68", "name": "Equity Bank Kenya" }] }'
      },
      {
        method: 'GET',
        path: '/api/payments/:transaction_id',
        title: 'Transaction status',
        auth: true,
        description: 'Get the current state of a single transaction.',
        params: [
          ['transaction_id', 'yes', 'Path parameter, e.g. MPX…, BNK…, or PSL…']
        ]
      },
      {
        method: 'GET',
        path: '/api/payments',
        title: 'List transactions',
        auth: true,
        description: 'List in-memory transactions. Optional query filters.',
        params: [
          ['status', 'query', 'pending | processing | completed | failed | cancelled'],
          ['method', 'query', 'mpesa | bank_transfer | pesalink']
        ]
      },
      {
        method: 'POST',
        path: '/api/payments/reset',
        title: 'Reset all transactions',
        auth: :admin,
        description: 'Clears all stored transactions. In production requires ADMIN_API_KEY.',
        body: '{}',
        params: []
      }
    ]
  end

  def mpesa_result_codes
    [
      [0, 'Success'],
      [1032, 'User cancelled'],
      [1037, 'Timeout (no PIN)'],
      [2001, 'Wrong PIN'],
      [1, 'Insufficient balance']
    ]
  end

  def pesalink_result_codes
    [
      ['00', 'Approved (sets an rrn)'],
      ['14', 'Invalid / not found account (or phone not linked)'],
      ['51', 'Insufficient funds'],
      ['61', 'Exceeds PesaLink amount limit (HTTP 422 on /send)'],
      ['91', 'Receiving bank timeout — reversed: true'],
      ['94', 'Duplicate transmission']
    ]
  end
end
