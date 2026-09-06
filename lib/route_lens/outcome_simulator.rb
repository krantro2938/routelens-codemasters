# frozen_string_literal: true

require "digest"

module RouteLens
  # Генерирует воспроизводимые результаты. Детерминированный режим моделирует
  # конверсию, approve_all изолирует влияние политики, а overrides используются
  # только для гарантированных сценариев повторов в тестах и demo.
  class OutcomeSimulator
    VALID_RESULTS = %w[approved rejected expired].freeze

    # Значение по умолчанию совпадает с CLI::DEFAULTS[:simulation]: одна ручка
    # не может иметь двух разных значений по умолчанию, иначе прямой вызов
    # библиотеки и запуск через bin/route дают разные результаты.
    def initialize(seed: 2026, mode: "deterministic", overrides: {})
      @seed = seed.to_s
      @mode = mode.to_s
      @overrides = overrides || {}
      raise ArgumentError, "Unknown simulation mode: #{@mode}" unless %w[approve_all deterministic].include?(@mode)
    end

    def call(operation, provider)
      provider_name = fetch(provider, "payment_system")
      operation_id = fetch(operation, "operation_id")
      override = @overrides["#{operation_id}|#{provider_name}"]
      result = override ? override.fetch("result", override[:result]).to_s : generated_result(operation, provider)
      raise ArgumentError, "Invalid simulated result #{result.inspect}" unless VALID_RESULTS.include?(result)

      latency = if override
                  override.fetch("latency_sec", override[:latency_sec] || generated_latency(operation, provider)).to_i
                else
                  generated_latency(operation, provider)
                end

      { "result" => result, "latency_sec" => [latency, 1].max }
    end

    private

    def generated_result(operation, provider)
      return "approved" if @mode == "approve_all"

      conversion = fetch(provider, "conversion_24h").to_f.clamp(0.0, 1.0)
      draw = unit_interval("result", operation, provider)
      return "approved" if draw < conversion

      unit_interval("failure", operation, provider) < 0.35 ? "expired" : "rejected"
    end

    def generated_latency(operation, provider)
      average = [fetch(provider, "avg_latency_sec").to_f, 1.0].max
      factor = 0.6 + unit_interval("latency", operation, provider) * 0.8
      (average * factor).round
    end

    def unit_interval(kind, operation, provider)
      # Один и тот же seed и вход всегда дают одинаковое число, независимо от
      # версии генератора случайных чисел и порядка других вызовов.
      key = [@seed, kind, fetch(operation, "operation_id"), fetch(provider, "payment_system")].join(":")
      Digest::SHA256.hexdigest(key)[0, 15].to_i(16).fdiv(16**15)
    end

    def fetch(hash, key)
      hash.fetch(key) { hash.fetch(key.to_sym) }
    end
  end
end
