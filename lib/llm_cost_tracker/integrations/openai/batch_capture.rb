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
            return unless batch.respond_to?(:status) && batch.status.to_s == "completed"

            output_file_id = batch.respond_to?(:output_file_id) ? batch.output_file_id : nil
            return unless output_file_id

            batch_id = batch.respond_to?(:id) ? batch.id : nil
            return unless batch_id && claim(batch_id)

            client = resource.instance_variable_get(:@client)
            host = Openai.client_host_for(resource)
            Openai.record_safely do
              io = client.files.content(output_file_id)
              capture_jsonl(io.respond_to?(:read) ? io.read : io.to_s, host: host)
            end
          end

          private

          def claim(batch_id)
            MUTEX.synchronize do
              @dedup ||= Set.new
              next false if @dedup.include?(batch_id)

              @dedup.clear if @dedup.size >= DEDUP_LIMIT
              @dedup.add(batch_id)
              true
            end
          end

          def capture_jsonl(jsonl, host:)
            jsonl.each_line do |line|
              line = line.strip
              next if line.empty?

              entry = parse_line(line)
              next unless entry

              response = entry.dig("response", "body")
              next unless response.is_a?(Hash) && response["usage"]

              record_result(response, host: host)
            end
          end

          def parse_line(line)
            JSON.parse(line)
          rescue JSON::ParserError
            nil
          end

          def record_result(response, host:)
            provider = Openai.provider_for_host(host)
            return if LlmCostTracker::Call.already_recorded?(provider: provider, provider_response_id: response["id"])

            event = LlmCostTracker::Providers::Openai::UsageParser.event_from_response(
              response: response,
              request: {},
              provider: provider,
              host: host,
              usage_source: LlmCostTracker::Capture::UsageSource::SDK_BATCH_RESULT,
              pricing_mode: "batch"
            )
            LlmCostTracker::Tracker.record(event: event) if event
          end
        end
      end
    end
  end
end
