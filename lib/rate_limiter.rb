# frozen_string_literal: true

require 'time'

# In-memory sliding-window rate limiter (per process).
# Suitable for single-instance deploys; use Redis for multi-instance clusters.
class RateLimiter
  def initialize(max_requests:, window_seconds:)
    @max_requests = max_requests
    @window_seconds = window_seconds
    @hits = {}
    @mutex = Mutex.new
  end

  def allow?(key)
    now = Time.now.to_f

    @mutex.synchronize do
      prune_expired!(now)
      timestamps = (@hits[key] ||= [])
      return false if timestamps.length >= @max_requests

      timestamps << now
      true
    end
  end

  def retry_after(key)
    @mutex.synchronize do
      timestamps = @hits[key]
      return @window_seconds unless timestamps&.any?

      oldest = timestamps.min
      remaining = @window_seconds - (Time.now.to_f - oldest)
      remaining.positive? ? remaining.ceil : 1
    end
  end

  private

  def prune_expired!(now)
    cutoff = now - @window_seconds
    @hits.each do |key, timestamps|
      timestamps.select! { |t| t > cutoff }
      @hits.delete(key) if timestamps.empty?
    end
  end
end
