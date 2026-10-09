# frozen_string_literal: true

require "active_support/core_ext/object/blank"
require "digest"
require "net/http"
require "openssl"
require "time"
require "uri"

require_relative "../../version"

module LlmCostTracker
  module Pricing
    module Sync
      class Fetcher
        Response = Data.define(:body, :etag, :last_modified, :not_modified) do
          def source_version
            etag || last_modified || Digest::SHA256.hexdigest(body.to_s)
          end
        end

        USER_AGENT = "llm_cost_tracker/#{LlmCostTracker::VERSION} price refresh".freeze
        MAX_REDIRECTS = 5
        MAX_BODY_BYTES = 2_097_152
        OPEN_TIMEOUT = 5
        READ_TIMEOUT = 10
        WRITE_TIMEOUT = 10

        def self.scrub_url(url)
          uri = URI.parse(url.to_s)
          uri.user = nil
          uri.password = nil
          uri.query = nil
          uri.fragment = nil
          uri.to_s
        rescue URI::InvalidURIError
          "[invalid url]"
        end

        def get(url, etag: nil, redirects: 0)
          safe_url = self.class.scrub_url(url)
          raise Error, "Too many redirects while fetching #{safe_url}" if redirects > MAX_REDIRECTS

          response, body = fetch_response(https_uri(url), etag)
          case response
          when Net::HTTPSuccess then build_response(response, body: body, not_modified: false)
          when Net::HTTPNotModified then build_response(response, body: nil, not_modified: true)
          when Net::HTTPRedirection then get(redirect_url(url, response), etag: etag, redirects: redirects + 1)
          else raise Error, "Unable to fetch #{safe_url}: HTTP #{response.code}"
          end
        rescue OpenSSL::SSL::SSLError, SocketError, SystemCallError, Timeout::Error => e
          raise Error, "Unable to fetch #{self.class.scrub_url(url)}: #{e.class}: #{e.message}"
        end

        private

        def https_uri(url)
          uri = URI.parse(url)
          raise Error, "Pricing snapshot URL must use https" unless uri.scheme == "https"

          uri
        end

        def redirect_url(url, response)
          location = response["location"]
          raise Error, "Redirect without location while fetching #{self.class.scrub_url(url)}" if location.blank?

          URI.join(url, location).to_s
        end

        def fetch_response(uri, etag)
          request = Net::HTTP::Get.new(uri)
          request["User-Agent"] = USER_AGENT
          request["If-None-Match"] = etag if etag
          body = nil
          response = Net::HTTP.start(
            uri.host,
            uri.port,
            use_ssl: true,
            open_timeout: OPEN_TIMEOUT,
            read_timeout: READ_TIMEOUT,
            write_timeout: WRITE_TIMEOUT
          ) do |http|
            http.request(request) do |streamed_response|
              body = limited_body(streamed_response) if streamed_response.is_a?(Net::HTTPSuccess)
            end
          end
          [response, body]
        end

        def limited_body(response)
          body = +""
          response.read_body do |chunk|
            chunk = chunk.to_s
            if body.bytesize + chunk.bytesize > MAX_BODY_BYTES
              raise Error, "Pricing snapshot response exceeds #{MAX_BODY_BYTES} bytes"
            end

            body << chunk
          end

          body
        end

        def build_response(response, not_modified:, body: response.body)
          Response.new(
            body: body,
            etag: response["etag"],
            last_modified: response["last-modified"],
            not_modified: not_modified
          )
        end
      end
    end
  end
end
