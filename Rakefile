# frozen_string_literal: true

require 'rake/testtask'

desc 'Start the Sinatra server'
task :server do
  exec 'ruby app.rb'
end

desc 'Start the server with auto-reload'
task :dev do
  exec 'bundle exec rerun ruby app.rb'
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

desc 'Show all available tasks'
task :help do
  system 'rake -T'
end

task default: :help