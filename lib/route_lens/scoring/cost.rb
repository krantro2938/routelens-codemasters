# frozen_string_literal: true

require_relative "component"

module RouteLens
  module Scoring
    class Cost < Component
      def value(provider:, state:, operation:, metrics:)
        provider_margin = Support.number(provider, :provider_margin_pct)
        merchant_margin = Support.number(provider, :merchant_margin_pct)
        return Support.clamp(provider_margin / merchant_margin) if merchant_margin.positive?

        normalization = Support.fetch(config, :normalization, {}) || {}
        reference = Support.number(normalization, :cost_reference_pct, 2.0)
        return 0.0 unless reference.positive?

        Support.clamp(provider_margin / reference)
      end
    end
  end
end
