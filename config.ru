# frozen_string_literal: true
# Vercel entrypoint — detected automatically; run locally with: bundle exec rackup

require_relative 'lib/app_config'
require_relative 'lib/middleware/https_only'

use PaymentSimulator::Middleware::HttpsOnly if AppConfig.enforce_https?
use Rack::MethodOverride

require_relative 'app'

run Sinatra::Application
