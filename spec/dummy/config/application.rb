# frozen_string_literal: true

require "rails"
require "action_controller/railtie"
require "llm_cost_tracker"
require "llm_cost_tracker/railtie"
require "llm_cost_tracker/engine"

module Dummy
  class Application < Rails::Application
    config.load_defaults 7.1

    config.root = File.expand_path("..", __dir__)
    config.eager_load = false
    config.secret_key_base = "test"
    config.logger = Logger.new(nil)
    config.hosts.clear
  end
end
