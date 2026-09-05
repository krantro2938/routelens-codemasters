# frozen_string_literal: true

require_relative "component"

module RouteLens
  module Scoring
    # Оценивает не сам размер цели, а уменьшение общей ошибки распределения
    # после виртуального назначения текущей операции выбранному провайдеру.
    class CountTargetGain < Component
      def value(provider:, state:, operation:, metrics:)
        counts = Support.metric_map(metrics, :count_by_provider, :counts, :routed_counts)
        total = Support.metric_total(metrics, %i[total_count routed_count], counts)
        name = Support.provider_name(provider)
        targets = target_map(metrics, provider)

        portfolio_gain(counts, targets, total, name)
      end

      private

      def target_map(metrics, provider)
        configured = Support.metric_map(metrics, :count_targets, :traffic_targets)
        configured = Support.fetch(config, :traffic_targets, {}) || {} if configured.empty?
        return normalize_targets(configured) unless configured.empty?

        providers = Support.candidates(metrics)
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

      def portfolio_gain(counts, targets, total, selected)
        names = (targets.keys + counts.keys.map(&:to_s) + [selected]).uniq
        before = distribution_error(names, counts, targets, total)
        projected = counts.transform_keys(&:to_s).transform_values(&:to_f)
        projected[selected] = projected.fetch(selected, 0.0) + 1.0
        after = distribution_error(names, projected, targets, total + 1.0)
        Support.clamp((before - after) / 2.0, -1.0, 1.0)
      end

      def distribution_error(names, counts, targets, total)
        names.sum do |name|
          actual = total.positive? ? Support.named_value(counts, name) / total : 0.0
          (actual - targets.fetch(name, 0.0)).abs
        end
      end
    end
  end
end
