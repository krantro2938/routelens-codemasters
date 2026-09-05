# frozen_string_literal: true

require_relative "component"

module RouteLens
  module Scoring
    class AmountPreference < Component
      def value(provider:, state:, operation:, metrics:)
        band = Support.config_for_provider(config, :preferred_amount_bands, provider)
        minimum = Support.fetch(band, :min, Support.fetch(provider, :preferred_amount_min, nil))
        maximum = Support.fetch(band, :max, Support.fetch(provider, :preferred_amount_max, nil))
        return 0.0 if minimum.nil? && maximum.nil?

        amount = Support.number(operation, :amount)
        return 0.0 if minimum && amount < minimum.to_f
        return 0.0 if maximum && amount > maximum.to_f

        1.0
      end
    end
  end
end
