# frozen_string_literal: true

module RouteLens
  module Analytics
    # Безопасные преобразования и статистические функции для построения отчёта.
    # Некорректное необязательное значение заменяется предсказуемым default.
    module Support
      module_function

      def hash(value)
        return value if value.is_a?(Hash)

        candidate = value.respond_to?(:to_h) ? value.to_h : value
        candidate.is_a?(Hash) ? candidate : {}
      rescue TypeError, ArgumentError
        {}
      end

      def fetch(value, key, default = nil)
        source = hash(value)
        return source[key.to_s] if source.key?(key.to_s)
        return source[key.to_sym] if source.key?(key.to_sym)

        default
      end

      def number(value, default = 0.0)
        return default if value.nil? || value == ''

        Float(value)
      rescue ArgumentError, TypeError
        default
      end

      def integer(value, default = 0)
        return default if value.nil? || value == ''

        Integer(value)
      rescue ArgumentError, TypeError
        default
      end

      def percent(numerator, denominator)
        denominator = number(denominator)
        return 0.0 if denominator.zero?

        round(number(numerator) * 100.0 / denominator)
      end

      def round(value, digits = 2)
        number(value).round(digits)
      end

      def average(values)
        values = values.compact.map { |value| number(value) }
        return 0.0 if values.empty?

        round(values.sum / values.length)
      end

      def percentile(values, percentile)
        values = values.compact.map { |value| number(value) }.sort
        return 0.0 if values.empty?

        # Используется nearest-rank: для небольших выборок p95 остаётся
        # наблюдаемым значением, а не интерполяцией между операциями.
        rank = (percentile * values.length).ceil
        round(values[[rank - 1, 0].max])
      end

      def median(values)
        values = values.compact.map { |value| number(value) }.sort
        return 0.0 if values.empty?

        middle = values.length / 2
        return round(values[middle]) if values.length.odd?

        round((values[middle - 1] + values[middle]) / 2.0)
      end

      def date_part(value)
        value.to_s[/\A\d{4}-\d{2}-\d{2}/]
      end

      def period(values)
        dates = values.filter_map { |value| date_part(value) }.sort
        return nil if dates.empty?
        return dates.first if dates.first == dates.last

        "#{dates.first}..#{dates.last}"
      end

      def provider_name(provider)
        fetch(provider, 'payment_system') || fetch(provider, 'provider') || fetch(provider, 'name')
      end

      def provider_list(value)
        source = value.is_a?(Array) ? value : (value.respond_to?(:to_h) ? value.to_h : value)
        nested = fetch(source, 'providers')
        source = nested unless nested.nil?

        case source
        when Array
          source
        when Hash
          source.map do |name, provider|
            attributes = hash(provider).dup
            unless attributes.key?('payment_system') || attributes.key?(:payment_system)
              attributes['payment_system'] = name.to_s
            end
            attributes
          end
        else
          []
        end
      end
    end
  end
end
