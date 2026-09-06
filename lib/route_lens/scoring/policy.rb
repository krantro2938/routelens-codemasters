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

      # Допуск на округление процентов в конфигурации: 33.3+33.3+33.3 должно
      # оставаться валидным вектором, а 150% суммарно — нет.
      TARGET_SUM_TOLERANCE = 0.5

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
        validate_precision!
        validate_weights!
        validate_targets!
        validate_scoring_configuration!
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

      def validate_precision!
        return if @precision.between?(0, 12)

        raise ArgumentError, "policy precision must be an integer between 0 and 12"
      end

      def validate_targets!
        validate_target_vector!("volume", Support.fetch(@config, :volume_targets, {}))
        validate_target_vector!("count", Support.fetch(@config, :traffic_targets, {}))
      end

      # Вектор долей проверяется целиком: каждое значение по отдельности может
      # быть корректным процентом, но сумма 150% делает цели недостижимыми и
      # молча искажает вклад целевых компонентов на всей очереди.
      def validate_target_vector!(label, targets)
        targets = targets || {}
        unless targets.respond_to?(:to_h)
          raise ArgumentError, "#{label} targets must be an object"
        end

        values = targets.to_h.map do |provider, target|
          begin
            value = Float(target)
          rescue ArgumentError, TypeError
            raise ArgumentError, "#{label} target for #{provider} must be numeric"
          end
          unless value.finite? && value.between?(0.0, 100.0)
            raise ArgumentError, "#{label} target for #{provider} must be a finite number between 0 and 100"
          end

          value
        end
        return if values.empty?

        sum = values.sum
        return if (sum - 100.0).abs <= TARGET_SUM_TOLERANCE

        raise ArgumentError,
              "#{label} targets must sum to 100 (+/-#{TARGET_SUM_TOLERANCE}), got #{sum.round(4)}"
      end

      def validate_scoring_configuration!
        validate_amount_bands!
        validate_turnover_minimums!
        validate_normalization!
      end

      def validate_amount_bands!
        bands = Support.fetch(@config, :preferred_amount_bands, {}) || {}
        raise ArgumentError, "preferred_amount_bands must be an object" unless bands.respond_to?(:to_h)

        bands.to_h.each do |provider, raw_band|
          unless raw_band.respond_to?(:to_h)
            raise ArgumentError, "preferred_amount_bands.#{provider} must be an object"
          end

          band = raw_band.to_h
          minimum = optional_non_negative_number!(Support.fetch(band, :min, nil),
                                                   "preferred_amount_bands.#{provider}.min")
          maximum = optional_non_negative_number!(Support.fetch(band, :max, nil),
                                                   "preferred_amount_bands.#{provider}.max")
          if !minimum.nil? && !maximum.nil? && minimum > maximum
            raise ArgumentError, "preferred_amount_bands.#{provider}.min cannot exceed max"
          end
        end
      end

      def validate_turnover_minimums!
        minimums = Support.fetch(@config, :daily_turnover_min, {}) || {}
        raise ArgumentError, "daily_turnover_min must be an object" unless minimums.respond_to?(:to_h)

        minimums.to_h.each do |provider, raw_value|
          value = if raw_value.respond_to?(:to_h)
                    Support.fetch(raw_value.to_h, :amount, nil)
                  else
                    raw_value
                  end
          optional_non_negative_number!(value, "daily_turnover_min.#{provider}", required: true)
        end
      end

      def validate_normalization!
        normalization = Support.fetch(@config, :normalization, {}) || {}
        raise ArgumentError, "normalization must be an object" unless normalization.respond_to?(:to_h)

        %i[latency_reference_sec cost_reference_pct conversion_reference].each do |field|
          value = Support.fetch(normalization, field, nil)
          next if value.nil?

          number = finite_number!(value, "normalization.#{field}")
          raise ArgumentError, "normalization.#{field} must be greater than zero" unless number.positive?
        end
      end

      def optional_non_negative_number!(value, label, required: false)
        if value.nil? || value == ""
          raise ArgumentError, "#{label} must be specified" if required

          return nil
        end

        number = finite_number!(value, label)
        raise ArgumentError, "#{label} cannot be negative" if number.negative?

        number
      end

      def finite_number!(value, label)
        number = Float(value)
        raise ArgumentError, "#{label} must be a finite number" unless number.finite?

        number
      rescue TypeError, ArgumentError
        raise ArgumentError, "#{label} must be a finite number"
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
