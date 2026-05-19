# frozen_string_literal: true

require 'json'
require_relative 'api_docs'

module DocsHelpers
  module_function

  def prepare_endpoints(base_url)
    ApiDocs.endpoints.map do |ep|
      ep.merge(curl_example: build_curl(ep, base_url))
    end
  end

  def build_curl(ep, base_url)
    path = ep[:path].gsub(':transaction_id', 'MPXEXAMPLE123')
    url = "#{base_url}#{path}"
    lines = ["curl -X #{ep[:method]} \"#{url}\""]

    if ep[:auth]
      lines[0] += ' \\'
      lines << '  -H "Authorization: Bearer YOUR_API_KEY"'
    end

    if ep[:body]
      lines[-1] += ' \\' unless lines[-1].end_with?('\\')
      lines << '  -H "Content-Type: application/json" \\'
      lines << "  -d '#{JSON.generate(JSON.parse(ep[:body]))}'"
    end

    lines.join("\n")
  end
end
