# frozen_string_literal: true

require "active_record"

module LlmCostTracker
  module Ingestion
    class Lease < ActiveRecord::Base
    end
  end
end
