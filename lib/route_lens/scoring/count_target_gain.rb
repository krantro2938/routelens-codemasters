# frozen_string_literal: true

require_relative "target_gain"

module RouteLens
  module Scoring
    # Оценивает не сам размер цели, а уменьшение общей ошибки распределения
    # количества операций после виртуального назначения текущей операции.
    class CountTargetGain < TargetGain
      private

      def current_shares(metrics)
        Support.metric_map(metrics, :count_by_provider, :counts, :routed_counts)
      end

      def current_total(metrics, shares)
        Support.metric_total(metrics, %i[total_count routed_count], shares)
      end

      def increment_for(_operation)
        1.0
      end

      def target_map(metrics, provider)
        configured = Support.metric_map(metrics, :count_targets, :traffic_targets)
        configured = Support.fetch(config, :traffic_targets, {}) || {} if configured.empty?
        return normalize_targets(configured) unless configured.empty?

        providers = Support.portfolio_providers(metrics)
        providers = [provider] if providers.empty?
        providers.to_h do |item|
          [Support.provider_name(item), Support.number(item, :traffic_percentage) / 100.0]
        end
      end

      def normalize_targets(targets)
        # Конфигурация всегда хранит проценты, включая точное значение 1%.
        targets.to_h do |name, target|
          [name.to_s, Support.number({ value: target }, :value) / 100.0]
        end
      end
    end
  end
end
