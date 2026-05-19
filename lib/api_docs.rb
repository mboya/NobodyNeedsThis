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
        method: 'GET',
        path: '/api/payments/:transaction_id',
        title: 'Transaction status',
        auth: true,
        description: 'Get the current state of a single transaction.',
        params: [
          ['transaction_id', 'yes', 'Path parameter, e.g. MPX… or BNK…']
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
          ['method', 'query', 'mpesa | bank_transfer']
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
end
