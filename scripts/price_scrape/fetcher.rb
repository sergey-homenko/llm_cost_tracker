# frozen_string_literal: true

require "net/http"
require "openssl"
require "time"
require "uri"

module LlmCostTracker
  module PriceScrape
    class Fetcher
      DEFAULT_USER_AGENT = "llm_cost_tracker price scrape (+https://github.com/sergey-homenko/llm_cost_tracker)"
      OPEN_TIMEOUT = 5
      READ_TIMEOUT = 10
      MAX_REDIRECTS = 5
      MAX_ATTEMPTS = 3
      MAX_BODY_BYTES = 5_242_880
      RETRY_BASE_DELAY = 1.0

      Response = Data.define(:url, :body, :status, :fetched_at, :elapsed_ms)

      class Error < StandardError; end
      class NetworkError < Error; end
      class ServerError < Error; end

      def initialize(user_agent: DEFAULT_USER_AGENT, sleep: ->(seconds) { Kernel.sleep(seconds) })
        @user_agent = user_agent
        @sleep = sleep
      end

      def get(url)
        attempt = 0
        begin
          attempt += 1
          fetch_once(url)
        rescue NetworkError, ServerError
          raise if attempt >= MAX_ATTEMPTS

          @sleep.call(RETRY_BASE_DELAY * (2**(attempt - 1)))
          retry
        end
      end

      private

      def fetch_once(url, redirects = 0)
        raise Error, "too many redirects fetching #{url}" if redirects > MAX_REDIRECTS

        uri = URI.parse(url)
        raise Error, "non-https URL: #{url}" unless uri.scheme == "https"

        started = monotonic_ms
        response, body = perform_request(uri)
        elapsed = monotonic_ms - started

        handle_response(response, body, url, redirects, elapsed)
      rescue OpenSSL::SSL::SSLError, SocketError, SystemCallError, Timeout::Error => e
        raise NetworkError, "#{e.class}: #{e.message} fetching #{url}"
      end

      def perform_request(uri)
        request = Net::HTTP::Get.new(uri)
        request["User-Agent"] = @user_agent
        body = nil
        response = Net::HTTP.start(
          uri.host,
          uri.port,
          use_ssl: true,
          open_timeout: OPEN_TIMEOUT,
          read_timeout: READ_TIMEOUT
        ) do |http|
          http.request(request) do |streamed_response|
            body = limited_body(streamed_response) if streamed_response.is_a?(Net::HTTPSuccess)
          end
        end

        [response, body]
      end

      def handle_response(response, body, url, redirects, elapsed_ms)
        case response
        when Net::HTTPSuccess
          build_success(response, body, url, elapsed_ms)
        when Net::HTTPRedirection
          follow_redirect(response, url, redirects)
        when Net::HTTPClientError
          raise Error, "client error #{response.code} fetching #{url}"
        else
          raise ServerError, "server error #{response.code} fetching #{url}"
        end
      end

      def build_success(response, body, url, elapsed_ms)
        body ||= limited_body(response)
        raise Error, "empty response body from #{url}" if body.empty?

        Response.new(
          url: url,
          body: body.dup.force_encoding("utf-8"),
          status: response.code.to_i,
          fetched_at: Time.now.utc.iso8601,
          elapsed_ms: elapsed_ms
        )
      end

      def follow_redirect(response, url, redirects)
        location = response["location"]
        raise Error, "redirect without location from #{url}" if location.nil? || location.empty?

        fetch_once(URI.join(url, location).to_s, redirects + 1)
      end

      def limited_body(response)
        body = +""
        if response.respond_to?(:read_body)
          response.read_body do |chunk|
            chunk = chunk.to_s
            if body.bytesize + chunk.bytesize > MAX_BODY_BYTES
              raise Error, "response body exceeds #{MAX_BODY_BYTES} bytes"
            end

            body << chunk
          end
        else
          body = response.body.to_s
        end
        raise Error, "response body exceeds #{MAX_BODY_BYTES} bytes" if body.bytesize > MAX_BODY_BYTES

        body
      end

      def monotonic_ms
        (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).round
      end
    end
  end
end
