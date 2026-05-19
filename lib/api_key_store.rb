# frozen_string_literal: true

require 'net/http'
require 'json'
require 'securerandom'
require_relative 'app_config'

# Stores issued API keys. Uses Upstash Redis on Vercel when configured, otherwise memory.
module ApiKeyStore
  KEY_PREFIX = 'ps_live_'
  REDIS_KEY_PREFIX = 'apikey:'

  class Memory
    def initialize
      @keys = {}
      @mutex = Mutex.new
    end

    def register(key, metadata = {})
      @mutex.synchronize { @keys[key] = metadata.merge(registered_at: Time.now.utc.iso8601) }
      true
    end

    def valid?(key)
      @mutex.synchronize { @keys.key?(key) }
    end

    def revoke(key)
      @mutex.synchronize { @keys.delete(key) }
    end
  end

  class Upstash
    def initialize(url:, token:)
      @url = url.chomp('/')
      @token = token
    end

    def register(key, metadata = {})
      redis_set(key, JSON.generate(metadata))
    end

    def valid?(key)
      redis_get(key) != nil
    end

    def revoke(key)
      redis_del(key)
    end

    private

    def redis_key(key)
      "#{REDIS_KEY_PREFIX}#{key}"
    end

    def redis_get(key)
      uri = URI("#{@url}/get/#{redis_key(key)}")
      response = request(uri, Net::HTTP::Get)
      return nil unless response.is_a?(Net::HTTPSuccess)

      body = JSON.parse(response.body)
      body['result']
    end

    def redis_set(key, value)
      encoded = URI.encode_www_form_component(redis_key(key))
      uri = URI("#{@url}/set/#{encoded}/#{URI.encode_www_form_component(value)}")
      request(uri, Net::HTTP::Get).is_a?(Net::HTTPSuccess)
    end

    def redis_del(key)
      encoded = URI.encode_www_form_component(redis_key(key))
      uri = URI("#{@url}/del/#{encoded}")
      request(uri, Net::HTTP::Get).is_a?(Net::HTTPSuccess)
    end

    def request(uri, method_class)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 5
      http.read_timeout = 5
      req = method_class.new(uri)
      req['Authorization'] = "Bearer #{@token}"
      http.request(req)
    end
  end

  class << self
    def generate_key
      "#{KEY_PREFIX}#{SecureRandom.hex(24)}"
    end

    def register(key, metadata = {})
      store.register(key, metadata)
    end

    def valid?(key)
      return false if key.nil? || key.empty?
      return true if AppConfig.env_api_keys.include?(key)

      store.valid?(key)
    end

    def revoke(key)
      store.revoke(key)
    end

    def store
      @store ||= build_store
    end

    def using_redis?
      store.is_a?(Upstash)
    end

    private

    def build_store
      url = ENV['UPSTASH_REDIS_REST_URL'].to_s.strip
      token = ENV['UPSTASH_REDIS_REST_TOKEN'].to_s.strip
      return Upstash.new(url: url, token: token) if !url.empty? && !token.empty?

      Memory.new
    end
  end
end
