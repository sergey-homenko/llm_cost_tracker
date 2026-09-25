# frozen_string_literal: true

require "json"

module LlmCostTracker
  module Integrations
    module Openai
      module BatchCapture
        DEDUP_LIMIT = 1024
        MUTEX = Mutex.new
        private_constant :DEDUP_LIMIT, :MUTEX

        class << self
          def maybe_capture(batch, resource:)
            return unless Openai.active?
            return unless %w[completed expired cancelled].include?(batch.status.to_s)
            return unless batch.output_file_id && batch.id
            return if captured?(batch.id)

            client = resource.instance_variable_get(:@client)
            host = Openai.client_host_for(resource)
            Openai.record_safely do
              io = client.files.content(batch.output_file_id)
              deferred = capture_jsonl(io.respond_to?(:read) ? io.read : io.to_s, host: host, model: batch.model)
              mark_captured(batch.id)
              raise deferred if deferred
            end
          end

          private

          def captured?(batch_id)
            MUTEX.synchronize { @dedup&.include?(batch_id) || false }
          end

          def mark_captured(batch_id)
            MUTEX.synchronize do
              @dedup ||= Set.new
              @dedup.clear if @dedup.size >= DEDUP_LIMIT
              @dedup.add(batch_id)
            end
          end

          def capture_jsonl(jsonl, host:, model:)
            deferred = nil
            jsonl.each_line do |line|
              line = line.strip
              next if line.empty?

              entry = parse_line(line)
              next unless entry

              response = entry.dig("response", "body")
              next unless response.is_a?(Hash) && response["usage"]

              record_result({ "id" => entry["id"] }.merge(response), host: host, model: model)
            rescue LlmCostTracker::BudgetExceededError, LlmCostTracker::UnknownPricingError => e
              deferred ||= e
            end
            deferred
          end

          def parse_line(line)
            JSON.parse(line)
          rescue JSON::ParserError
            nil
          end

          def record_result(response, host:, model:)
            provider = Openai.provider_for_host(host)
            return if LlmCostTracker::Call.already_recorded?(provider: provider, provider_response_id: response["id"])

            parser = LlmCostTracker::Providers::Openai::ResponseParser
            event = parser.event_from_response(
              response: response,
              request: { "model" => model },
              provider: provider,
              host: host,
              usage_source: LlmCostTracker::Usage::Source::SDK_BATCH_RESULT,
              # /v1/batches runs regional processing only on the us and eu hosts.
              pricing_mode: parser.combined_pricing_mode(
                host: (host if host.to_s.match?(/\A(?:us|eu)\./i)),
                model: response["model"] || model,
                service_tier: "batch"
              )
            )
            LlmCostTracker::Tracker.record(event: event) if event
          end
        end
      end
    end
  end
end
