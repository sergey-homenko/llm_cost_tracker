# frozen_string_literal: true

require "digest"
require "net/http"
require "openssl"
require "time"
require "uri"

module LlmCostTracker
  module PriceSync
    class Fetcher
      Response = Data.define(:body, :etag, :last_modified, :not_modified, :fetched_at) do
        def source_version
          etag || last_modified || Digest::SHA256.hexdigest(body.to_s)
        end
      end

      USER_AGENT = "llm_cost_tracker price refresh"
      MAX_REDIRECTS = 5
      MAX_BODY_BYTES = 2_097_152
      OPEN_TIMEOUT = 5
      READ_TIMEOUT = 10
      WRITE_TIMEOUT = 10

      def get(url, etag: nil, redirects: 0)
        raise Error, "Too many redirects while fetching #{url}" if redirects > MAX_REDIRECTS

        uri = URI.parse(url)
        raise Error, "Pricing snapshot URL must use https" unless uri.scheme == "https"

        request = Net::HTTP::Get.new(uri)
        request["User-Agent"] = USER_AGENT
        request["If-None-Match"] = etag if etag

        response = Net::HTTP.start(
          uri.host,
          uri.port,
          use_ssl: uri.scheme == "https",
          open_timeout: OPEN_TIMEOUT,
          read_timeout: READ_TIMEOUT,
          write_timeout: WRITE_TIMEOUT
        ) do |http|
          http.request(request)
        end

        case response
        when Net::HTTPSuccess
          body = response.body.to_s
          raise Error, "Pricing snapshot response exceeds #{MAX_BODY_BYTES} bytes" if body.bytesize > MAX_BODY_BYTES

          build_response(response, body: body, not_modified: false)
        when Net::HTTPNotModified
          build_response(response, body: nil, not_modified: true)
        when Net::HTTPRedirection
          location = response["location"]
          raise Error, "Redirect without location while fetching #{url}" if location.nil? || location.empty?

          get(URI.join(url, location).to_s, etag: etag, redirects: redirects + 1)
        else
          raise Error, "Unable to fetch #{url}: HTTP #{response.code}"
        end
      rescue OpenSSL::SSL::SSLError, SocketError, SystemCallError, Timeout::Error => e
        raise Error, "Unable to fetch #{url}: #{e.class}: #{e.message}"
      end

      private

      def build_response(response, not_modified:, body: response.body)
        Response.new(
          body: body,
          etag: response["etag"],
          last_modified: response["last-modified"],
          not_modified: not_modified,
          fetched_at: Time.now.utc.iso8601
        )
      end
    end
  end
end
