# frozen_string_literal: true

require_relative "component"

module RouteLens
  module Scoring
    # Измеряет, насколько сумма текущей операции приближает весь денежный
    # портфель к целевым долям объёма.
    class VolumeTargetGain < Component
      def value(provider:, state:, operation:, metrics:)
        volumes = Support.metric_map(metrics, :volume_by_provider, :volumes, :routed_volumes)
        total = Support.metric_total(metrics, %i[total_volume routed_volume], volumes)
        amount = Support.number(operation, :amount)
        name = Support.provider_name(provider)
        targets = target_map(metrics, provider)

        portfolio_gain(volumes, targets, total, name, amount)
      end

      private

      def target_map(metrics, provider)
        configured = Support.metric_map(metrics, :volume_targets)
        configured = Support.fetch(config, :volume_targets, {}) || {} if configured.empty?
        providers = Support.candidates(metrics)
        providers = [provider] if providers.empty?
        providers.to_h do |item|
          name = Support.provider_name(item)
          configured_target = Support.fetch(configured, name, nil)
          # Новый провайдер работает без правки политики: сначала используется
          # его volume_share_pct, затем traffic_percentage как явный fallback.
          target = if configured_target.nil?
                     explicit = Support.fetch(item, :volume_share_pct, nil)
                     explicit.nil? ? Support.number(item, :traffic_percentage) : explicit.to_f
                   else
                     configured_target.to_f
                   end
          [name, target / 100.0]
        end
      end

      def portfolio_gain(volumes, targets, total, selected, amount)
        names = (targets.keys + volumes.keys.map(&:to_s) + [selected]).uniq
        before = distribution_error(names, volumes, targets, total)
        projected = volumes.transform_keys(&:to_s).transform_values(&:to_f)
        projected[selected] = projected.fetch(selected, 0.0) + amount
        after = distribution_error(names, projected, targets, total + amount)
        Support.clamp((before - after) / 2.0, -1.0, 1.0)
      end

      def distribution_error(names, volumes, targets, total)
        names.sum do |name|
          actual = total.positive? ? Support.named_value(volumes, name) / total : 0.0
          (actual - targets.fetch(name, 0.0)).abs
        end
      end
    end
  end
end
