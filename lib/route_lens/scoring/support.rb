# frozen_string_literal: true

module RouteLens
  module Scoring
    module Support
      module_function

      def fetch(source, key, default = nil)
        return default if source.nil?

        if source.respond_to?(:key?)
          return source[key] if source.key?(key)

          string_key = key.to_s
          return source[string_key] if source.key?(string_key)
        end

        if source.respond_to?(:[]) && !source.is_a?(Array)
          value = source[key]
          value = source[key.to_s] if value.nil?
          return value unless value.nil?
        end

        return source.public_send(key) if source.respond_to?(key)

        default
      end

      def number(source, key, default = 0.0)
        value = fetch(source, key, default)
        return default.to_f if value.nil?

        Float(value)
      rescue ArgumentError, TypeError
        default.to_f
      end

      def provider_name(provider)
        fetch(provider, :payment_system, fetch(provider, :name, "unknown")).to_s
      end

      def state_value(provider, state, key, default = 0.0)
        value = fetch(state, key, nil)
        value.nil? ? number(provider, key, default) : value.to_f
      end

      def clamp(value, minimum = 0.0, maximum = 1.0)
        [[value.to_f, minimum].max, maximum].min
      end

      def safe_ratio(numerator, denominator, default: 0.0)
        denominator = denominator.to_f
        return default.to_f if denominator <= 0.0

        numerator.to_f / denominator
      end

      def named_value(collection, name, default = 0.0)
        return default.to_f unless collection.respond_to?(:key?)

        value = if collection.key?(name)
                  collection[name]
                elsif collection.key?(name.to_sym)
                  collection[name.to_sym]
                else
                  default
                end
        value.nil? ? default.to_f : value.to_f
      end

      def metric_map(metrics, *keys)
        keys.each do |key|
          value = fetch(metrics, key, nil)
          return value if value.respond_to?(:key?)
        end
        {}
      end

      def metric_total(metrics, explicit_keys, collection)
        explicit_keys.each do |key|
          value = fetch(metrics, key, nil)
          return value.to_f unless value.nil?
        end
        collection.values.compact.sum(&:to_f)
      end

      def candidates(metrics)
        Array(fetch(metrics, :eligible_providers, fetch(metrics, :providers, [])))
      end

      def config_for_provider(config, section, provider)
        mapping = fetch(config, section, {}) || {}
        fetch(mapping, provider_name(provider), {}) || {}
      end
    end
  end
end
