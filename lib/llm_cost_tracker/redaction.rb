# frozen_string_literal: true

require "uri"

module LlmCostTracker
  module Redaction
    REDACTED = "[REDACTED]"

    TOKEN = Regexp.union(
      /sk-(?:ant-|admin-|proj-|svcacct-|live-|test-)?[A-Za-z0-9_-]{16,}/,
      /AKIA[0-9A-Z]{16}/,
      /gh[opsur]_[A-Za-z0-9]{16,}/,
      /github_pat_[A-Za-z0-9_]{20,}/,
      /eyj[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/i,
      /bearer\s+[A-Za-z0-9_.-]{20,}/i,
      /xox[abprs]-[A-Za-z0-9-]{10,}/,
      /(?:sk|rk|pk)_(?:live|test)_[A-Za-z0-9]{20,}/,
      /AIza[0-9A-Za-z_-]{35}/
    )
    AFTER_ESCAPE = /(?<=%[0-9A-Fa-f]{2})|(?<=\\u00[0-9A-Fa-f]{2})/
    WHOLE_TOKEN = /\A(?:#{TOKEN})\z/
    EMBEDDED_TOKEN = /(?:(?<![A-Za-z0-9_-])|#{AFTER_ESCAPE})(?:#{TOKEN})(?![A-Za-z0-9_-])/

    PARAM_NAMES = %w[
      key api_key api-key apikey x-api-key x-goog-api-key subscription-key ocp-apim-subscription-key
      token access_token refresh_token id_token auth_token session_token x-amz-security-token
      secret client_secret password passwd sig signature x-amz-signature x-goog-signature
      x-amz-credential x-goog-credential
    ].freeze
    KEY_HEADER_NAMES = %w[
      x-api-key x-goog-api-key api-key apikey subscription-key ocp-apim-subscription-key x-amz-security-token
      access-token refresh-token id-token client-secret password
    ].freeze

    PARAM = /(?:\A|(?<=[?&;\s"'(,\[{|:])|#{AFTER_ESCAPE})(#{Regexp.union(PARAM_NAMES).source})
             (?:=|%3d|\\u003d)[^&\s"'\\<>;,)]+/ix
    HEADER_PREFIX = /(?<![\w-])((?:HTTP_)?\\?["']?(?:%s)\\?["']?\s*(?:=>|:)\s*\\?["']?)/
    AUTH_HEADER = /#{format(HEADER_PREFIX.source, '(?:proxy[-_])?authorization')}
                   (?:[A-Za-z][A-Za-z0-9-]*\s+)?[^\s"'\\,;)}]{6,}/ix
    KEY_HEADER = /#{format(HEADER_PREFIX.source, KEY_HEADER_NAMES.map { |name| name.gsub('-', '[-_]') }.join('|'))}
                  [^\s"'\\,;)}]{6,}/ix
    USERINFO = %r{://[^/\s@?#]+@}
    PREFILTER = /[=:@%\\]|AIza|sk-|[srp]k_|AKIA|gh[opsur]_|github_pat_|eyj|bearer|xox/i
    private_constant :TOKEN, :AFTER_ESCAPE, :WHOLE_TOKEN, :EMBEDDED_TOKEN, :PARAM_NAMES, :KEY_HEADER_NAMES
    private_constant :PARAM, :HEADER_PREFIX, :AUTH_HEADER, :KEY_HEADER, :USERINFO, :PREFILTER

    class << self
      def secret?(value)
        string = readable(value)
        string.bytesize >= 16 && WHOLE_TOKEN.match?(string)
      end

      def text(value)
        string = readable(value)
        return string unless PREFILTER.match?(string)

        string
          .gsub(USERINFO) { "://#{REDACTED}@" }
          .gsub(AUTH_HEADER) { "#{Regexp.last_match(1)}#{REDACTED}" }
          .gsub(KEY_HEADER) { "#{Regexp.last_match(1)}#{REDACTED}" }
          .gsub(PARAM) { "#{Regexp.last_match(1)}=#{REDACTED}" }
          .gsub(EMBEDDED_TOKEN, REDACTED)
      end

      def url(value)
        uri = URI.parse(value.to_s)
        uri.user = nil
        uri.password = nil
        uri.query = nil
        uri.fragment = nil
        uri.to_s
      rescue URI::InvalidURIError
        readable(value).sub(USERINFO, "://").split(/[?#]/, 2).first.to_s
      end

      def error(error, limit: nil)
        message = "#{error.class}: #{text(error.message)}"
        return message unless limit && message.bytesize > limit

        message.byteslice(0, limit).scrub("")
      end

      private

      def readable(value)
        string = value.to_s
        unless string.encoding.ascii_compatible?
          string = string.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
        end
        string.valid_encoding? ? string : string.scrub
      end
    end
  end
end
