# frozen_string_literal: true

require "faraday"
require "json"

module LlmCostTracker
  module Middleware
    class Faraday < ::Faraday::Middleware
      module Body
        MULTIPART_MODEL = /name="model"\r\n(?:[^\r\n]+\r\n)*\r\n([^\r\n]+)\r\n/

        class << self
          def read(body)
            case body
            when String then body
            when nil then ""
            when Hash, Array then body.to_json
            else body.to_str if body.respond_to?(:to_str)
            end
          end

          def multipart_model_json(env, parser)
            body = env.body
            multipart = env.request_headers["Content-Type"].to_s.start_with?("multipart/form-data")
            return nil unless parser && multipart && body.respond_to?(:read) && body.respond_to?(:rewind)

            model = scan_model(body)
            model && { "model" => model }.to_json
          rescue StandardError => e
            Logging.warn("Unable to read the model from a multipart request: #{e.class}: #{e.message}")
            nil
          end

          private

          def scan_model(io)
            window = String.new(encoding: Encoding::BINARY)
            while (chunk = io.read(65_536))
              window << chunk.b
              model = window[MULTIPART_MODEL, 1]
              return model.force_encoding(Encoding::UTF_8) if model

              window = window.byteslice([window.bytesize - 512, 0].max..)
            end
          ensure
            io.rewind
          end
        end
      end
    end
  end
end
