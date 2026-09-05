# frozen_string_literal: true

require_relative "../config_loader"
require_relative "count_target_gain"
require_relative "volume_target_gain"
require_relative "conversion"
require_relative "priority"
require_relative "amount_preference"
require_relative "load"
require_relative "capacity"
require_relative "turnover_obligation"
require_relative "latency"
require_relative "cost"

module RouteLens
  module Scoring
    class Policy
      COMPONENTS = {
        "count_target_gain" => CountTargetGain,
        "volume_target_gain" => VolumeTargetGain,
        "conversion" => Conversion,
        "priority" => Priority,
        "amount_preference" => AmountPreference,
        "capacity" => Capacity,
        "turnover_obligation" => TurnoverObligation,
        "load" => Load,
        "latency" => Latency,
        "cost" => Cost
      }.freeze

      DIRECTIONS = {
        "load" => -1.0,
        "latency" => -1.0,
        "cost" => -1.0
      }.freeze

      attr_reader :name, :weights, :preset

      def self.load(path, preset: nil)
        new(ConfigLoader.load(path), preset: preset)
      end

      def initialize(config = nil, preset: nil, **keyword_config)
        @config = config.nil? ? keyword_config : config
        @preset = preset&.to_s
        policy = selected_policy
        @name = Support.fetch(policy, :name, "unnamed_policy").to_s
        @precision = Integer(Support.fetch(policy, :precision, 6))
        @weights = normalize_weights(Support.fetch(policy, :weights, {}))
        # Конфигурация проверяется один раз при старте, чтобы неверный вес или
        # процент не привёл к частично обработанной очереди.
        validate_weights!
        validate_targets!
        @components = @weights.to_h do |component_name, _weight|
          [component_name, COMPONENTS.fetch(component_name).new(@config)]
        end
      end

      def available_presets
        presets.keys.map(&:to_s).sort
      end

      def volume_target_for(provider)
        name = Support.provider_name(provider)
        configured = Support.fetch(Support.fetch(@config, :volume_targets, {}), name, nil)
        return configured.to_f unless configured.nil?

        explicit = Support.fetch(provider, :volume_share_pct, nil)
        return explicit.to_f unless explicit.nil?

        Support.number(provider, :traffic_percentage)
      end

      def volume_target_source_for(provider)
        name = Support.provider_name(provider)
        configured = Support.fetch(Support.fetch(@config, :volume_targets, {}), name, nil)
        return "policy.volume_targets" unless configured.nil?
        return "volume_share_pct" unless Support.fetch(provider, :volume_share_pct, nil).nil?

        "traffic_percentage_fallback"
      end

      def score(provider:, state: nil, operation:, metrics: {})
        # Каждый фактор возвращает нормализованное значение. Направление явно
        # превращает нагрузку, задержку и стоимость в штрафы.
        breakdown = @components.to_h do |component_name, component|
          raw = rounded(component.call(provider: provider, state: state, operation: operation, metrics: metrics))
          weight = @weights.fetch(component_name)
          direction = DIRECTIONS.fetch(component_name, 1.0)
          contribution = rounded(raw * weight * direction)
          [component_name, { raw: raw, weight: weight, direction: direction, contribution: contribution }]
        end
        total = rounded(breakdown.values.sum { |entry| entry.fetch(:contribution) })
        tie_break = tie_break_for(provider)

        {
          policy: name,
          total: total,
          breakdown: breakdown,
          tie_break: tie_break,
          sort_key: [-total, tie_break.fetch(:priority), tie_break.fetch(:latency_sec), tie_break.fetch(:provider)]
        }
      end

      def rank(candidates:, operation:, metrics: {}, states: {})
        # sort_key обеспечивает стабильный результат при равных суммах:
        # приоритет, задержка, затем имя провайдера.
        enriched_metrics = metrics.merge(eligible_providers: candidates)
        candidates.map do |provider|
          provider_name = Support.provider_name(provider)
          state = Support.fetch(states, provider_name, nil)
          { provider: provider, result: score(provider: provider, state: state, operation: operation, metrics: enriched_metrics) }
        end.sort_by { |entry| entry.fetch(:result).fetch(:sort_key) }
      end

      private

      def selected_policy
        base = Support.fetch(@config, :policy, @config) || {}
        return base if @preset.nil? || @preset.empty?

        override = Support.fetch(presets, @preset, nil)
        unless override.is_a?(Hash)
          available = presets.keys.map(&:to_s).sort.join(", ")
          raise ArgumentError, "unknown policy preset #{@preset.inspect}; available: #{available}"
        end

        base.to_h.merge(override.to_h).merge(
          "weights" => Support.fetch(override, :weights, Support.fetch(base, :weights, {}))
        )
      end

      def presets
        raw = Support.fetch(@config, :presets, {}) || {}
        raw.respond_to?(:to_h) ? raw.to_h : {}
      end

      def normalize_weights(raw_weights)
        return {} unless raw_weights.respond_to?(:to_h)

        raw_weights.to_h.transform_keys(&:to_s).transform_values do |value|
          Float(value)
        rescue ArgumentError, TypeError
          raise ArgumentError, "policy weight must be numeric: #{value.inspect}"
        end
      end

      def validate_weights!
        unknown = @weights.keys - COMPONENTS.keys
        raise ArgumentError, "unknown scoring components: #{unknown.join(', ')}" unless unknown.empty?
        raise ArgumentError, "at least one scoring component must be configured" if @weights.empty?
        raise ArgumentError, "policy weights must be non-negative" if @weights.values.any?(&:negative?)
        raise ArgumentError, "policy weights must be finite" unless @weights.values.all?(&:finite?)
      end

      def validate_targets!
        targets = Support.fetch(@config, :volume_targets, {}) || {}
        return unless targets.respond_to?(:to_h)

        targets.to_h.each do |provider, target|
          begin
            value = Float(target)
          rescue ArgumentError, TypeError
            raise ArgumentError, "volume target for #{provider} must be numeric"
          end
          unless value.finite? && value.between?(0.0, 100.0)
            raise ArgumentError, "volume target for #{provider} must be a finite number between 0 and 100"
          end
        end
      end

      def tie_break_for(provider)
        {
          priority: Support.number(provider, :priority, Float::INFINITY),
          latency_sec: Support.number(provider, :avg_latency_sec, Float::INFINITY),
          provider: Support.provider_name(provider)
        }
      end

      def rounded(value)
        value.round(@precision)
      end
    end
  end
end
