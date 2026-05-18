# frozen_string_literal: true

require 'rake/testtask'
require 'shellwords'

desc 'Start via Rack (same entrypoint as Vercel)'
task :rack do
  port = ENV.fetch('PORT', 9292)
  exec "bundle exec rackup config.ru -p #{port} -o 0.0.0.0"
end

desc 'Start the Sinatra server directly'
task :server do
  exec 'ruby app.rb'
end

desc 'Start with auto-reload (direct mode)'
task :dev do
  exec 'bundle exec rerun ruby app.rb'
end

desc 'Start with auto-reload (Rack mode, Vercel parity)'
task 'dev:rack' do
  port = ENV.fetch('PORT', 9292)
  exec "bundle exec rerun 'rackup config.ru -p #{port} -o 0.0.0.0'"
end

desc 'Run demo scripts'
task :demo do
  exec 'ruby demo_scripts.rb'
end

desc 'Test the payment simulator directly'
task :test_simulator do
  exec 'ruby payment_simulator.rb'
end

desc 'Install dependencies'
task :install do
  sh 'bundle install'
end

desc 'Check if server is running'
task :check do
  require 'net/http'
  begin
    uri = URI('http://localhost:3000/api/health')
    response = Net::HTTP.get_response(uri)
    if response.is_a?(Net::HTTPSuccess)
      puts '✓ Server is running and healthy!'
    else
      puts '✗ Server is running but not responding correctly'
    end
  rescue Errno::ECONNREFUSED
    puts '✗ Server is not running'
    puts 'Start it with: rake server'
  end
end

desc 'Reset all transactions'
task :reset do
  require 'net/http'
  require 'json'
  
  uri = URI('http://localhost:3000/api/payments/reset')
  http = Net::HTTP.new(uri.host, uri.port)
  request = Net::HTTP::Post.new(uri.path)
  response = http.request(request)
  
  if response.is_a?(Net::HTTPSuccess)
    puts '✓ All transactions reset successfully'
  else
    puts '✗ Failed to reset transactions'
  end
rescue Errno::ECONNREFUSED
  puts '✗ Server is not running'
  puts 'Start it with: rake server'
end

desc 'Test auto-complete functionality'
task :test_auto_complete do
  exec 'ruby test_auto_complete.rb'
end

desc 'Full E2E test suite (requires running servers, or use ci)'
task :e2e do
  exec 'ruby test_e2e.rb'
end

desc 'Syntax check Ruby sources'
task :syntax do
  files = (
    %w[app.rb config.ru payment_simulator.rb webhook_receiver.rb Rakefile] +
    Dir['test_*.rb'] +
    Dir['lib/**/*.rb']
  ).sort
  sh "ruby -c #{files.shelljoin}"
end

desc 'Run CI locally (syntax + E2E with services)'
task :ci do
  Rake::Task[:syntax].invoke
  sh 'bash scripts/ci.sh'
end

desc 'Show all available tasks'
task :help do
  system 'rake -T'
end

task default: :help