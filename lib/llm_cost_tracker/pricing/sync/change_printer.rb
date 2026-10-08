# frozen_string_literal: true

module LlmCostTracker
  module Pricing
    module Sync
      class ChangePrinter
        def self.call(changes, suspicious: [], output: $stdout)
          new(output).call(changes, suspicious)
        end

        def initialize(output)
          @output = output
        end

        def call(changes, suspicious)
          print_suspicious(suspicious)
          print_models(changes.except("service_charges"))
          print_service_charges(changes["service_charges"])
        end

        private

        def print_suspicious(findings)
          return unless findings.any?

          @output.puts "  suspicious changes (refresh writes them only with FORCE=1): #{findings.size}"
          findings.each { |finding| @output.puts "    - #{finding}" }
        end

        def print_models(changes)
          @output.puts "  changed models: #{changes.size}"
          changes.each do |model, fields|
            @output.puts "    - #{model}"
            fields.each { |field, values| @output.puts "      #{field}: #{transition(values)}" }
          end
        end

        def print_service_charges(changes)
          return if changes.nil? || changes.empty?

          @output.puts "  changed service charges: #{changes.values.sum(&:size)}"
          changes.each do |provider, components|
            components.each { |component, values| @output.puts "    - #{provider}.#{component}: #{transition(values)}" }
          end
        end

        def transition(values)
          "#{values['from'].inspect} -> #{values['to'].inspect}"
        end
      end
    end
  end
end
