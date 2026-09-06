# frozen_string_literal: true

require_relative "component"

module RouteLens
  module Scoring
    # Сравнивает цену провайдера с текущими допустимыми кандидатами. Policy
    # применяет к этому значению отрицательное направление как к штрафу.
    class Cost < Component
      def value(provider:, state:, operation:, metrics:)
        current = cost_ratio(provider)
        ratios = Support.candidates(metrics).map { |item| cost_ratio(item) }
        position = Support.relative_position(current, ratios)
        return Support.clamp(current) if position.nil?

        position
      end

      private

      # Доля маржи мерчанта, которую забирает провайдер. Если маржа мерчанта
      # неизвестна, цена приводится к абсолютному эталону из конфигурации.
      def cost_ratio(provider)
        provider_margin = Support.number(provider, :provider_margin_pct)
        merchant_margin = Support.number(provider, :merchant_margin_pct)
        return provider_margin / merchant_margin if merchant_margin.positive?

        normalization = Support.fetch(config, :normalization, {}) || {}
        reference = Support.number(normalization, :cost_reference_pct, 2.0)
        return 0.0 unless reference.positive?

        provider_margin / reference
      end
    end
  end
end
