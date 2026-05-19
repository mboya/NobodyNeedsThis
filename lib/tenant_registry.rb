# frozen_string_literal: true

require_relative '../payment_simulator'
require_relative 'app_config'

# One simulator (transaction store) per API key.
module TenantRegistry
  @mutex = Mutex.new
  @simulators = {}

  class << self
    def for(api_key)
      @mutex.synchronize do
        @simulators[api_key] ||= PaymentSimulator::Simulator.new(success_rate: AppConfig.success_rate)
      end
    end

    def reset!(api_key)
      @mutex.synchronize do
        @simulators.delete(api_key)
      end
    end
  end
end
