# frozen_string_literal: true

module LlmCostTracker
  module Integrations
    module RubyLlm
      module V1
        module ProviderPatch
          def complete(*args, **kwargs, &)
            seam = V1.blocking_seam(self, :record_completion, has_block: block_given?)
            V1.wrap_blocking(args, kwargs, **seam) { super }
          end

          def embed(*args, **kwargs)
            V1.wrap_blocking(args, kwargs, **V1.blocking_seam(self, :record_embedding)) { super }
          end

          def transcribe(*args, **kwargs)
            V1.wrap_blocking(args, kwargs, **V1.blocking_seam(self, :record_transcription)) { super }
          end

          def paint(*args, **kwargs)
            V1.wrap_blocking(args, kwargs, **V1.blocking_seam(self, :record_image)) { super }
          end

          def moderate(*args, **kwargs)
            V1.wrap_blocking(args, kwargs, **V1.blocking_seam(self, :record_moderation)) { super }
          end
        end

        module GeminiTranscriptionPatch
          def transcribe(*args, **kwargs)
            V1.wrap_blocking(args, kwargs, **V1.blocking_seam(self, :record_transcription)) { super }
          end
        end

        module ResponseBodyPatch
          def parse_transcription_response(response, **)
            V1.keep_usage(super, response.body)
          end

          def parse_embedding_response(response, **)
            V1.keep_usage(super, response.body)
          end
        end

        module StreamPatch
          private

          def stream_response(...)
            body = @llm_cost_tracker_stream_body = {}
            super.tap { |message| message.raw.instance_variable_set(Reply::KEPT_BODY, body) }
          end

          def build_on_data_handler(*, &handler)
            body = @llm_cost_tracker_stream_body
            super do |data|
              if body && data.is_a?(Hash)
                body.deep_merge!(data.values_at("message", "response").find { |part| part.is_a?(Hash) } || data)
              end
              handler.call(data)
            end
          end
        end
      end
    end
  end
end
