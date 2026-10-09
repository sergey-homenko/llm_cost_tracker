# frozen_string_literal: true

module LlmCostTracker
  module Tags
    module Context
      KEY = :llm_cost_tracker_tags

      class << self
        def with(tags)
          stack = Fiber[KEY] || []
          scope = [Thread.current, Sanitizer.call((tags || {}).to_h)]
          Fiber[KEY] = stack + [scope]
          yield
        ensure
          scope&.clear
          Fiber[KEY] = stack
        end

        def tags
          config = LlmCostTracker.configuration
          base = config.tags.static_sanitized_default || Sanitizer.call(call_default_tags(config.tags.default))
          base.merge(scoped)
        end

        def scoped
          Array(Fiber[KEY]).each_with_object({}) do |(owner, tags), merged|
            merged.merge!(tags) if owner.equal?(Thread.current)
          end
        end

        def call_default_tags(proc_or_lambda)
          (proc_or_lambda.call || {}).to_h
        rescue StandardError => e
          Logging.warn("LlmCostTracker tags.default proc raised: #{e.class}: #{e.message}; using empty default tags")
          {}
        end
      end
    end
  end
end
