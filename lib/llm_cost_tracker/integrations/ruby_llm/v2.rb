# frozen_string_literal: true

require "active_support/notifications"
require_relative "../base"
require_relative "v2/attempt"

module LlmCostTracker
  module Integrations
    module RubyLlm
      module V2
        extend Base

        minimum_version "2.0.0"
        maximum_version "3.0.0"

        OPERATIONS = %i[chat embedding image transcription moderation speech ocr rerank judgment].freeze
        JOBS = %w[batch.ruby_llm video_job.ruby_llm research_job.ruby_llm].freeze
        EVENTS = [*OPERATIONS, :compaction, :request, :usage].map { |name| "#{name}.ruby_llm" }.concat(JOBS).freeze
        FRAMES = :llm_cost_tracker_ruby_llm_frames
        CACHE_CREATED = :llm_cost_tracker_ruby_llm_cache_created
        SEAMS = {
          build_chunk: %w[Protocols::Anthropic Protocols::ChatCompletions Protocols::Responses Protocols::Gemini
                          Protocols::Interactions Protocols::Converse Providers::OpenRouter::ChatCompletions
                          Protocols::Cohere],
          parse_completion_body: %w[Protocols::Anthropic Protocols::ChatCompletions Protocols::Responses
                                    Protocols::Gemini Protocols::Interactions Protocols::Converse
                                    Protocols::Mistral::Conversations Providers::Mistral::ChatCompletions],
          parse_embedding_response: %w[Protocols::ChatCompletions Protocols::Gemini Providers::VertexAI::EmbedContent
                                       Providers::Perplexity::Embeddings Protocols::Cohere],
          parse_transcription_response: %w[Protocols::ChatCompletions Protocols::Gemini],
          parse_speech_response: %w[Protocols::Gemini],
          stream_transcription: %w[Protocols::ChatCompletions],
          transcribe: %w[Protocol Protocols::Deepgram Protocols::Gemini::LiveTranscription],
          parse_image_responses: %w[Protocols::ChatCompletions Protocols::Gemini Providers::XAI::Images],
          parse_cache_response: %w[Protocols::Gemini],
          messages: %w[Batch],
          results: %w[Batch],
          current_workflow: %w[Support::Instrumentation]
        }.freeze
        StreamTranscriptionBridge = Module.new do
          def stream_transcription(*, **, &block)
            super do |chunk|
              V2.observe(:stream_transcription, chunk.raw, self)
              block.call(chunk)
            end
          end
        end
        TranscribeBridge = Module.new do
          def transcribe(*, **, &block)
            V2.observe(:transcribe, {}, self) if block
            super
          end
        end
        BatchBridge = Module.new do
          %i[messages results].each { |name| define_method(name) { V2.collect(self) { super() } } }
        end
        BRIDGES = (SEAMS.keys - %i[stream_transcription transcribe messages results current_workflow]).to_h do |seam|
          bridge = Module.new do
            define_method(seam) do |value, *args, **options, &block|
              V2.observe(seam, options.fetch(:raw, value), self)
              super(value, *args, **options, &block)
            end
          end
          [seam, const_set("#{seam.to_s.camelize}Bridge", bridge)]
        end.merge(
          stream_transcription: StreamTranscriptionBridge,
          transcribe: TranscribeBridge,
          messages: BatchBridge,
          results: BatchBridge
        ).freeze
        RECORDED = ObjectSpace::WeakKeyMap.new
        Frame = Struct.new(*%i[payload attempts compaction request_started_at latency_ms window response raw provider
                               workflow])

        class << self
          def integration_name = :ruby_llm

          def install
            validate_contract!
            Logging.warn(untested_version_message) if untested_version?
            @subscriptions ||= EVENTS.map { |name| ActiveSupport::Notifications.subscribe(name, self) }
            RubyLLM.config.instrumenter ||= ActiveSupport::Notifications
            BRIDGES.each do |seam, bridge|
              SEAMS[seam].filter_map { |target| seam_owner(target, seam) }.each do |owner|
                owner.prepend(bridge) unless owner == bridge
              end
            end
          end

          def status
            name = integration_name.to_s
            problems = version_problems + target_problems
            if problems.any?
              return Check.new(:warn, name, "#{name} integration cannot be installed: #{problems.join('; ')}")
            end
            return Check.new(:warn, name, untested_version_message) if untested_version?
            return Check.new(:warn, name, "#{name} integration is enabled but not installed") unless @subscriptions

            instrumenter = RubyLLM.config.instrumenter
            unless instrumenter == ActiveSupport::Notifications
              message = "RubyLLM.config.instrumenter is #{instrumenter.inspect}, not ActiveSupport::Notifications, " \
                        "so RubyLLM calls are not recorded"
              return Check.new(:warn, name, message)
            end
            missing = missing_seams
            return Check.new(:ok, name, "#{name} integration installed") if missing.empty?

            message = "#{name} integration installed, but these RubyLLM methods are missing, so what they carry " \
                      "is not read: #{missing.join(', ')}"
            Check.new(:warn, name, message)
          end

          def start(name, _id, payload)
            case name
            when "usage.ruby_llm" then nil
            when "request.ruby_llm" then start_request(payload)
            else start_operation(name, payload)
            end
          end

          def finish(name, _id, payload)
            case name
            when "usage.ruby_llm" then add_attempt(payload) unless %i[video research].include?(payload[:operation])
            when "request.ruby_llm" then finish_request(payload)
            else finish_operation(payload)
            end
          end

          def observe(seam, value, protocol = nil)
            record_safely do
              next record_cache_storage(value) if seam == :parse_cache_response

              frame = frames.last
              next unless frame

              frame.provider = protocol&.provider
              next if seam == :parse_completion_body && value.is_a?(Hash)
              next frame.raw = value if seam == :parse_completion_body
              next frame.response = value unless seam == :build_chunk

              (frame.window ||= Attempt.stream_window).push(value)
            end
          end

          def collect(batch)
            frame = Frame.new(
              payload: batch,
              attempts: [],
              workflow: "RubyLLM::Support::Instrumentation".safe_constantize.try(:current_workflow)
            )
            frames << frame
            results = yield
            record_batch(batch, results, frame) if active?
            results
          ensure
            frames.delete_if { |open| open.equal?(frame) }
          end

          private

          def target_problems = defined?(RubyLLM.config) ? [] : ["RubyLLM is not loaded"]

          def missing_seams
            SEAMS.flat_map do |seam, targets|
              targets.reject { |target| seam_owner(target, seam) }.map { |target| "RubyLLM::#{target}##{seam}" }
            end
          end

          def seam_owner(target, seam)
            "RubyLLM::#{target}".safe_constantize&.instance_method(seam)&.owner
          rescue NameError
            nil
          end

          def frames = Thread.current[FRAMES] ||= []

          def start_operation(name, payload)
            return unless active?

            enforce_budget!(
              request: budget_request(payload),
              provider: payload[:provider].to_s,
              tags: (LlmCostTracker::Tracker.build_tags(**tags_for(payload)) if payload[:workflow_id])
            )
            frames << Frame.new(payload, [], name.start_with?("compaction")) if JOBS.exclude?(name)
          end

          def finish_operation(payload)
            index = frames.rindex { |frame| frame.payload.equal?(payload) }
            return unless index

            errors = frames.slice!(index..).flat_map { |frame| flush(frame) }
            raise errors.first if errors.any? && !payload[:exception]
          end

          def start_request(payload)
            cache = payload[:method] == :post && payload[:url].to_s.end_with?("cachedContents")
            Thread.current[CACHE_CREATED] = (payload[:provider].to_s if cache)
            enforce_budget!(request: {}, provider: payload[:provider].to_s) if cache
            frame = frames.last
            frame&.request_started_at = Timing.now_monotonic
            frame&.latency_ms = nil
          end

          def finish_request(payload)
            frame = frames.last
            return unless frame

            frame.latency_ms = Timing.elapsed_ms(frame.request_started_at) if frame.request_started_at
            frame.workflow = payload.slice(:workflow_id, :workflow_name, :workflow_step_name)
          end

          def record_cache_storage(data)
            event = Providers::Gemini::Parser.new.cache_storage_event(data) if Thread.current[CACHE_CREATED] && active?
            LlmCostTracker::Tracker.record(event: event.with(provider: Thread.current[CACHE_CREATED])) if event
          rescue LlmCostTracker::BudgetExceededError
            nil
          end

          def add_attempt(usage)
            frame = frames.last
            if OPERATIONS.exclude?(usage[:operation])
              record_safely { record_attempt(usage, {}, nil, final: false) } if active?
            elsif frame
              raw = frame.raw unless usage[:status] == :succeeded && usage[:tokens].to_h.empty?
              frame.attempts << [usage, frame.latency_ms, frame.window&.events, raw]
              frame.window = nil
              frame.raw = nil if raw
            end
          end

          def flush(frame)
            final = frame.attempts.rindex { |usage, *| usage[:status] == :succeeded }
            final ||= frame.attempts.size - 1 if frame.response
            payload = frame.compaction ? frame.payload.except(:provider_options) : frame.payload
            frame.attempts.each_with_index.filter_map do |(usage, latency_ms, events, raw), index|
              attempt = { final: index == final, events: events, response: frame.response, raw: raw,
                          provider: frame.provider }
              record_safely { record_attempt(usage, payload, latency_ms, **attempt) }
              nil
            rescue *CALLER_ERRORS => e
              e
            end
          end

          def record_attempt(usage, payload, latency_ms, **attempt)
            event = Attempt.event(usage, payload, **attempt)
            LlmCostTracker::Tracker.record(event: event, latency_ms: latency_ms, **tags_for(usage)) if event
          end

          def record_batch(batch, results, frame)
            errors = Array(results).each_with_index.filter_map do |result, index|
              next if result.nil? || RECORDED.key?(result)

              record_safely do
                record_batch_result(batch, result, index, frame)
                RECORDED[result] = true
              end
              nil
            rescue *CALLER_ERRORS => e
              e
            end
            raise errors.first if errors.any?
          end

          def record_batch_result(batch, result, index, frame)
            usage = { operation: result.is_a?(RubyLLM::Embedding) ? :embedding : :chat, provider: batch.provider,
                      model: result.model || batch.chats.to_a[index]&.model&.id, status: :succeeded,
                      tokens: result.tokens }
            base = frame.provider&.api_base || RubyLLM.config.try("#{batch.provider}_api_base")
            event = Attempt.batch_event(usage, result, base)
            return unless event

            id = event.provider_response_id || "#{batch.id}/#{index}"
            return if Call.already_recorded?(provider: event.provider, provider_response_id: id)

            record_once(event.with(provider_response_id: id), **tags_for(frame.workflow.to_h))
          end

          def tags_for(payload)
            context = LlmCostTracker::Tags::Context.tags
            run_id = payload[:workflow_id] if context.none? { |key, value| key.to_s == "run_id" && !value.to_s.empty? }
            { context_tags: context,
              metadata: { run_id: run_id }.compact.merge(payload.slice(:workflow_name, :workflow_step_name).compact) }
          end

          def budget_request(payload)
            input = payload[:input_messages]&.map { |message| message.try(:content).then { |c| c.try(:text) || c } }
            { model: payload[:model], input: input || payload.values_at(:input, :prompt, :query) }
          end
        end
      end
    end
  end
end
