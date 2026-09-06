# frozen_string_literal: true

require "csv"
require "json"
require "time"

require_relative "provider_state"

module RouteLens
  # Единая ошибка для отсутствующих, повреждённых или несовместимых входов.
  # CLI ловит её до записи итоговых файлов.
  class InputError < StandardError; end

  class InputLoader
    class << self
      # overrides приходят из секции provider_overrides в policy YAML: входной
      # снимок организаторов остаётся байт-в-байт неизменным, а параметры правил
      # (например лимит запросов в минуту) настраиваются конфигурацией.
      def load_provider_snapshot(path, overrides: nil)
        data = load_json(path)
        unless data.is_a?(Hash) && data["providers"].is_a?(Array)
          raise InputError, "#{path}: expected an object containing a providers array"
        end

        overrides = normalize_provider_overrides(overrides)
        providers = data["providers"].each_with_index.map do |provider, index|
          context = "#{path}: providers[#{index}]"
          raise InputError, "#{context}: expected an object" unless provider.is_a?(Hash)

          # Переопределение сливается ДО валидации, поэтому настроенное значение
          # проходит ровно те же числовые и диапазонные проверки, что и родное.
          merged = provider.merge(overrides.fetch(provider["payment_system"].to_s, {}))
          validate_provider!(merged, context)
          ProviderState.new(merged)
        end

        unknown = overrides.keys - providers.map(&:payment_system)
        unless unknown.empty?
          raise InputError, "provider_overrides: unknown payment_system: #{unknown.sort.join(', ')}"
        end

        duplicate_names = providers.group_by(&:payment_system).select { |_name, matches| matches.length > 1 }.keys
        unless duplicate_names.empty?
          raise InputError, "#{path}: duplicate payment_system values: #{duplicate_names.join(', ')}"
        end

        data.merge("providers" => providers)
      end

      def load_providers(path, overrides: nil)
        load_provider_snapshot(path, overrides: overrides).fetch("providers")
      end

      def load_operations(path)
        data = load_json(path)
        raise InputError, "#{path}: expected an array of operations" unless data.is_a?(Array)

        operations = data.each_with_index.map do |operation, index|
          validate_operation!(operation, "#{path}: operations[#{index}]")
          deep_copy(operation)
        end

        duplicate_ids = operations.group_by { |op| op["operation_id"] }
                                  .select { |_id, matches| matches.length > 1 }.keys
        unless duplicate_ids.empty?
          raise InputError, "#{path}: duplicate operation_id values: #{duplicate_ids.join(', ')}"
        end

        operations
      end

      def load_history(path)
        rows = CSV.read(path, headers: true)
        required = %w[operation_id created_at amount bank payment_system status latency_sec]
        missing = required - Array(rows.headers)
        raise InputError, "#{path}: missing CSV columns: #{missing.join(', ')}" unless missing.empty?

        rows.each_with_index.map do |row, index|
          item = row.to_h
          context = "#{path}: row #{index + 2}"
          require_string!(item, "operation_id", context)
          require_string!(item, "payment_system", context)
          item["amount"] = numeric!(item["amount"], "amount", context)
          item["latency_sec"] = numeric!(item["latency_sec"], "latency_sec", context)
          item
        end
      rescue CSV::MalformedCSVError => e
        raise InputError, "#{path}: invalid CSV: #{e.message}"
      rescue Errno::ENOENT, Errno::EACCES => e
        raise InputError, "cannot read #{path}: #{e.message}"
      end

      private

      def load_json(path)
        JSON.parse(File.read(path))
      rescue JSON::ParserError => e
        raise InputError, "#{path}: invalid JSON: #{e.message}"
      rescue Errno::ENOENT, Errno::EACCES => e
        raise InputError, "cannot read #{path}: #{e.message}"
      end

      def validate_provider!(provider, context)
        raise InputError, "#{context}: expected an object" unless provider.is_a?(Hash)

        require_string!(provider, "payment_system", context)
        require_string!(provider, "status", context)

        numeric_fields = %w[
          traffic_percentage priority limit_amount_min limit_amount_max daily_amount_limit
          daily_approved_amount in_progress_count_limit in_progress_count
          in_progress_amount_limit in_progress_amount available_requisites conversion_24h
          avg_latency_sec provider_margin_pct merchant_margin_pct requests_per_minute_limit
          requests_last_minute current_requests_per_minute volume_share_pct daily_turnover_min
        ]
        numeric_fields.each do |field|
          next unless provider.key?(field) && !provider[field].nil?

          numeric!(provider[field], field, context)
        end

        validate_range!(provider, "conversion_24h", 0.0, 1.0, context)
        validate_range!(provider, "traffic_percentage", 0.0, 100.0, context)
        validate_range!(provider, "volume_share_pct", 0.0, 100.0, context)

        minimum = provider["limit_amount_min"]
        maximum = provider["limit_amount_max"]
        if !minimum.nil? && !maximum.nil? && Float(minimum) > Float(maximum)
          raise InputError, "#{context}: limit_amount_min cannot exceed limit_amount_max"
        end

        %w[exclude_banks allow_negative_agreement self_provider].each do |field|
          next unless provider.key?(field)
          next if provider[field] == true || provider[field] == false

          raise InputError, "#{context}: #{field} must be boolean"
        end

        if provider.key?("banks") && !provider["banks"].is_a?(Array)
          raise InputError, "#{context}: banks must be an array"
        end
      end

      def normalize_provider_overrides(overrides)
        return {} if overrides.nil?
        raise InputError, "provider_overrides must be an object" unless overrides.is_a?(Hash)

        overrides.to_h do |name, attributes|
          unless attributes.is_a?(Hash)
            raise InputError, "provider_overrides[#{name}]: expected an object of provider attributes"
          end

          [name.to_s, attributes.transform_keys(&:to_s)]
        end
      end

      def validate_range!(item, field, minimum, maximum, context)
        return unless item.key?(field) && !item[field].nil?

        value = Float(item[field])
        return if value.between?(minimum, maximum)

        raise InputError, "#{context}: #{field} must be between #{minimum} and #{maximum}"
      end

      def validate_operation!(operation, context)
        raise InputError, "#{context}: expected an object" unless operation.is_a?(Hash)

        require_string!(operation, "operation_id", context)
        amount = numeric!(operation["amount"], "amount", context)
        raise InputError, "#{context}: amount must be greater than zero" unless amount.positive?
        # bank не входит в обязательный контракт операции: одна выплата без банка
        # не должна обнулять весь файл. Пустой банк деградирует консервативно —
        # BankRule пропускает провайдеров со списком banks (bank_not_in_list) и
        # оставляет допустимыми тех, у кого список пуст.

        return unless operation.key?("created_at") && operation["created_at"]

        Time.iso8601(operation["created_at"])
      rescue ArgumentError
        raise InputError, "#{context}: created_at must be an ISO 8601 timestamp"
      end

      def require_string!(item, field, context)
        value = item[field]
        return if value.is_a?(String) && !value.strip.empty?

        raise InputError, "#{context}: #{field} must be a non-empty string"
      end

      def numeric!(value, field, context)
        number = Float(value)
        raise ArgumentError unless number.finite?
        raise InputError, "#{context}: #{field} cannot be negative" if number.negative?

        number
      rescue ArgumentError, TypeError
        raise InputError, "#{context}: #{field} must be a finite number"
      end

      def deep_copy(value)
        Marshal.load(Marshal.dump(value))
      end
    end
  end
end
