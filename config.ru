# frozen_string_literal: true

require_relative 'app'

# Rack configuration
use Rack::ShowExceptions
use Rack::MethodOverride

run Sinatra::Application
