# frozen_string_literal: true

require_relative "../base"

module LlmCostTracker
  module Pricing::Scrape
    module Providers
      class Openai < Base
        MODEL_ID_BY_DISPLAY_NAME = {
          "chatgpt-4o-latest" => "chatgpt-4o-latest", "codex-mini-latest" => "codex-mini-latest",
          "gpt-3.5-turbo" => "gpt-3.5-turbo", "gpt-4" => "gpt-4", "gpt-4-0613" => "gpt-4",
          "gpt-4-turbo" => "gpt-4-turbo", "gpt-4-turbo-2024-04-09" => "gpt-4-turbo",
          "gpt-4.1" => "gpt-4.1", "gpt-4.1-mini" => "gpt-4.1-mini",
          "gpt-4.1-nano" => "gpt-4.1-nano", "gpt-4o" => "gpt-4o",
          "gpt-4o-2024-05-13" => "gpt-4o-2024-05-13",
          "gpt-4o-audio-preview" => "gpt-4o-audio-preview", "gpt-4o-mini" => "gpt-4o-mini",
          "gpt-4o-mini-audio-preview" => "gpt-4o-mini-audio-preview",
          "gpt-4o-mini-realtime-preview" => "gpt-4o-mini-realtime-preview",
          "gpt-4o-realtime-preview" => "gpt-4o-realtime-preview",
          "gpt-audio" => "gpt-audio", "gpt-audio-1.5" => "gpt-audio-1.5",
          "gpt-audio-mini" => "gpt-audio-mini",
          "gpt-5" => "gpt-5", "gpt-5-chat-latest" => "gpt-5-chat-latest",
          "gpt-5-codex" => "gpt-5-codex", "gpt-5-mini" => "gpt-5-mini",
          "gpt-5-nano" => "gpt-5-nano", "gpt-5-pro" => "gpt-5-pro",
          "gpt-5.1" => "gpt-5.1", "gpt-5.1-chat-latest" => "gpt-5.1-chat-latest",
          "gpt-5.1-codex" => "gpt-5.1-codex", "gpt-5.1-codex-max" => "gpt-5.1-codex-max",
          "gpt-5.1-codex-mini" => "gpt-5.1-codex-mini", "gpt-5.2" => "gpt-5.2",
          "gpt-5.2-chat-latest" => "gpt-5.2-chat-latest", "gpt-5.2-codex" => "gpt-5.2-codex",
          "gpt-5.2-pro" => "gpt-5.2-pro", "gpt-5.3-chat-latest" => "gpt-5.3-chat-latest",
          "gpt-5.3-codex" => "gpt-5.3-codex", "gpt-5.4" => "gpt-5.4",
          "gpt-5.4 (<272K context length)" => "gpt-5.4", "gpt-5.4-mini" => "gpt-5.4-mini",
          "gpt-5.4-nano" => "gpt-5.4-nano", "gpt-5.4-pro" => "gpt-5.4-pro",
          "gpt-5.4-pro (<272K context length)" => "gpt-5.4-pro", "gpt-5.5" => "gpt-5.5",
          "gpt-5.5 (<272K context length)" => "gpt-5.5", "gpt-5.5-pro" => "gpt-5.5-pro",
          "gpt-5.5-pro (<272K context length)" => "gpt-5.5-pro",
          "gpt-5.6-luna" => "gpt-5.6-luna", "gpt-5.6-sol" => "gpt-5.6-sol",
          "gpt-5.6-terra" => "gpt-5.6-terra", "o1" => "o1", "o1-mini" => "o1-mini",
          "gpt-realtime" => "gpt-realtime", "gpt-realtime-1.5" => "gpt-realtime-1.5",
          "gpt-realtime-mini" => "gpt-realtime-mini", "o1-pro" => "o1-pro", "o3" => "o3",
          "o3-mini" => "o3-mini", "o3-pro" => "o3-pro",
          "o4-mini" => "o4-mini",
          "gpt-image-1" => "gpt-image-1", "gpt-image-1-mini" => "gpt-image-1-mini",
          "gpt-image-1.5" => "gpt-image-1.5", "gpt-image-2" => "gpt-image-2",
          "chatgpt-image-latest" => "chatgpt-image-latest"
        }.freeze
      end
    end
  end
end
