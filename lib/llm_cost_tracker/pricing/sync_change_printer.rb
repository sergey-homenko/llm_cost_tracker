# frozen_string_literal: true

module LlmCostTracker
  module Pricing
    module SyncChangePrinter
      class << self
        def call(changes, output: $stdout)
          service_changes = changes["service_charges"]
          model_changes = changes.except("service_charges")

          output.puts "  changed models: #{model_changes.size}"
          model_changes.each do |model, fields|
            output.puts "    - #{model}"
            fields.each do |field, values|
              output.puts "      #{field}: #{values['from'].inspect} -> #{values['to'].inspect}"
            end
          end

          return if service_changes.nil? || service_changes.empty?

          output.puts "  changed service charges: #{service_changes.values.sum(&:size)}"
          service_changes.each do |provider, components|
            components.each do |component, values|
              output.puts "    - #{provider}.#{component}: " \
                          "#{values['from'].inspect} -> #{values['to'].inspect}"
            end
          end
        end
      end
    end
  end
end
