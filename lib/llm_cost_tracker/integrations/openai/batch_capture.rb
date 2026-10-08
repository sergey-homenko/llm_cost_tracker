# frozen_string_literal: true

require "json"

module LlmCostTracker
  module Integrations
    module Openai
      module BatchCapture
        FINISHED_STATUSES = %w[completed expired cancelled].freeze
        DEDUP_LIMIT = 1024
        MUTEX = Mutex.new
        private_constant :FINISHED_STATUSES, :DEDUP_LIMIT, :MUTEX

        class << self
          def capture(batch, client:)
            return unless Openai.active? && capturable?(batch)

            host = Openai.client_host(client)
            Openai.record_safely do
              jsonl = client.files.content(batch.output_file_id).read
              deferred = capture_jsonl(jsonl, host: host, model: batch.model)
              mark_captured(batch.id)
              raise deferred if deferred
            end
          end

          private

          def capturable?(batch)
            FINISHED_STATUSES.include?(batch.status.to_s) && batch.output_file_id && batch.id && !captured?(batch.id)
          end

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
              entry = parse_line(line)
              next unless entry

              response = entry.dig("response", "body")
              next unless response.is_a?(Hash) && response["usage"]

              record_result({ "id" => entry["id"] }.merge(response), host: host, model: model)
            rescue BudgetExceededError, UnknownPricingError => e
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
            return if Call.already_recorded?(provider: provider, provider_response_id: response["id"])

            event = Providers::Openai::ResponseParser.event_from_response(
              response: response,
              request: { "model" => model },
              provider: provider,
              host: host,
              usage_source: Usage::Source::SDK_BATCH_RESULT,
              pricing_mode: batch_pricing_mode(host, response["model"] || model)
            )
            Openai.record_once(event)
          end

          def batch_pricing_mode(host, model)
            Providers::Openai::ResponseParser.combined_pricing_mode(
              host: (host if host.to_s.match?(/\A(?:us|eu)\./i)), model: model, service_tier: "batch"
            )
          end
        end
      end
    end
  end
end
