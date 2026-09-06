# frozen_string_literal: true

require_relative "target_gain"

module RouteLens
  module Scoring
    # Измеряет, насколько сумма текущей операции приближает весь денежный
    # портфель к целевым долям объёма.
    class VolumeTargetGain < TargetGain
      private

      def current_shares(metrics)
        Support.metric_map(metrics, :volume_by_provider, :volumes, :routed_volumes)
      end

      def current_total(metrics, shares)
        Support.metric_total(metrics, %i[total_volume routed_volume], shares)
      end

      def increment_for(operation)
        Support.number(operation, :amount)
      end

      def target_map(metrics, provider)
        configured = Support.metric_map(metrics, :volume_targets)
        configured = Support.fetch(config, :volume_targets, {}) || {} if configured.empty?
        providers = Support.portfolio_providers(metrics)
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
    end
  end
end
