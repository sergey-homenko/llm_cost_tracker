# frozen_string_literal: true

module LlmCostTracker
  module Tags
    module Context
      KEY = :llm_cost_tracker_tags

      class << self
        def with(tags)
          stack = Fiber[KEY] || []
          shared = Thread.current[KEY]
          scope = [Thread.current, Sanitizer.call((tags || {}).to_h)]
          Fiber[KEY] = stack + [scope]
          Thread.current[KEY] = Array(shared) + [scope.dup]
          yield
        ensure
          scope&.clear
          Fiber[KEY] = stack
          Thread.current[KEY] = shared
        end

        def tags
          config = LlmCostTracker.configuration
          base = config.tags.static_sanitized_default || Sanitizer.call(call_default_tags(config.tags.default))
          base.merge(scoped)
        end

        def scoped
          current = Thread.current
          shared = Array(current[KEY]).reject { |owner, _| owner.equal?(current) }
          own = Array(Fiber[KEY]).select { |owner, _| owner.equal?(current) }
          (shared + own).each_with_object({}) { |(_, tags), merged| merged.merge!(tags) }
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
