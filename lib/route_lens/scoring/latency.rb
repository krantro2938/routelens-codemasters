# frozen_string_literal: true

require_relative "component"

module RouteLens
  module Scoring
    # Сравнивает задержку только с текущими допустимыми кандидатами. Если они
    # равны, используется абсолютный эталон из конфигурации.
    class Latency < Component
      def value(provider:, state:, operation:, metrics:)
        current = Support.number(provider, :avg_latency_sec)
        latencies = Support.candidates(metrics).map { |item| Support.number(item, :avg_latency_sec) }
        latencies << current
        minimum, maximum = latencies.minmax
        return normalized_reference(current) if maximum == minimum

        (current - minimum) / (maximum - minimum)
      end

      private

      def normalized_reference(value)
        normalization = Support.fetch(config, :normalization, {}) || {}
        reference = Support.number(normalization, :latency_reference_sec, 120.0)
        return 0.0 unless reference.positive?

        Support.clamp(value / reference)
      end
    end
  end
end
