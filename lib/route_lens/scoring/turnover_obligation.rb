# frozen_string_literal: true

require_relative "component"

module RouteLens
  module Scoring
    class TurnoverObligation < Component
      def value(provider:, state:, operation:, metrics:)
        configured = Support.config_for_provider(config, :daily_turnover_min, provider)
        minimum = configured.is_a?(Hash) ? Support.fetch(configured, :amount, nil) : configured
        minimum = Support.fetch(provider, :daily_turnover_min, nil) if minimum.nil? || minimum == {}
        return 0.0 if minimum.nil? || minimum.to_f <= 0.0

        current = Support.state_value(provider, state, :daily_approved_amount, 0.0)
        Support.clamp((minimum.to_f - current) / minimum.to_f)
      end
    end
  end
end
