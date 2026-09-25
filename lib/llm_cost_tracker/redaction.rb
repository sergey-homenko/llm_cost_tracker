# frozen_string_literal: true

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
    EMBEDDED_TOKEN = /(?<![A-Za-z0-9_-])(?:#{TOKEN})(?![A-Za-z0-9_-])/
    PARAM = /(?<![A-Za-z0-9])((?:api)?key|token|secret|password|sig(?:nature)?)=[^&\s"']+/i
    HEADER = /((?:authorization|api-key)["']?\s*(?:=>|:)\s*["']?)(?:[A-Za-z]+\s+)?[^\s"',;]+/i
    USERINFO = %r{://[^/\s@?#]+@}
    private_constant :TOKEN, :EMBEDDED_TOKEN, :PARAM, :HEADER, :USERINFO

    def self.text(value)
      value.to_s.scrub
           .gsub(USERINFO, "://#{REDACTED}@")
           .gsub(HEADER, "\\1#{REDACTED}")
           .gsub(PARAM, "\\1=#{REDACTED}")
           .gsub(EMBEDDED_TOKEN, REDACTED)
    end
  end
end
