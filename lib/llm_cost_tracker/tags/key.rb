# frozen_string_literal: true

module LlmCostTracker
  module Tags
    module Key
      PATTERN = /\A[\w.-]+\z/
      MAX_BYTESIZE = 64

      class << self
        def validate!(key, error_class: ArgumentError)
          key = key.to_s
          if key.bytesize > MAX_BYTESIZE
            raise error_class, "tag key exceeds #{MAX_BYTESIZE} bytes: #{key[0, 16].inspect}..."
          end
          return key if key.match?(PATTERN)

          raise error_class, "invalid tag key: #{key.inspect}"
        end
      end
    end
  end
end
