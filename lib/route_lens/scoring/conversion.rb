# frozen_string_literal: true

require_relative "component"

module RouteLens
  module Scoring
    # Сравнивает conversion_24h с текущими допустимыми кандидатами так же, как
    # это делают latency и priority. Общая шкала обязательна: пока компонент
    # отдавал сырые 0.79..0.91, вес 1.5 покупал разброс всего в 0.18, и любой
    # полнодиапазонный фактор перебивал разницу в конверсии.
    class Conversion < Component
      def value(provider:, state:, operation:, metrics:)
        current = Support.number(provider, :conversion_24h)
        conversions = Support.candidates(metrics).map { |item| Support.number(item, :conversion_24h) }
        position = Support.relative_position(current, conversions)
        return normalized_reference(current) if position.nil?

        position
      end

      private

      def normalized_reference(value)
        # Кандидаты неразличимы: остаётся абсолютная шкала, где эталон —
        # конверсия 100%. conversion_reference позволяет сузить её в конфиге.
        normalization = Support.fetch(config, :normalization, {}) || {}
        reference = Support.number(normalization, :conversion_reference, 1.0)
        return 0.0 unless reference.positive?

        Support.clamp(value / reference)
      end
    end
  end
end
