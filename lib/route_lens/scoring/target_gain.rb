# frozen_string_literal: true

require_relative "component"

module RouteLens
  module Scoring
    # Общая механика целевых долей: ценность назначения измеряется уменьшением
    # суммарной ошибки распределения после виртуального добавления текущей
    # операции. Подклассы отличаются только тем, что именно они считают —
    # количество операций или денежный объём.
    class TargetGain < Component
      def value(provider:, state:, operation:, metrics:)
        shares = current_shares(metrics)
        total = current_total(metrics, shares)
        increment = increment_for(operation)
        targets = target_map(metrics, provider)
        selected = Support.provider_name(provider)
        gain = portfolio_gain(shares, targets, total, selected, increment)

        # Сырой выигрыш убывает как ~1/N по мере наполнения пакета, поэтому его
        # нельзя складывать с факторами постоянного масштаба: к концу очереди
        # цель просто переставала влиять на выбор. Делим на лучший достижимый
        # выигрыш среди текущих кандидатов — лучший получает ~1.0, худший ~-1.0,
        # а смысл «выигрыш именно от этой операции» сохраняется.
        scale = achievable_gain(shares, targets, total, increment, metrics, selected)
        return 0.0 unless scale.positive?

        Support.clamp(gain / scale, -1.0, 1.0)
      end

      private

      # Абстрактная часть контракта: подкласс отдаёт снимок уже назначенного,
      # его итог и вклад текущей операции.
      def current_shares(_metrics)
        raise NotImplementedError
      end

      def current_total(_metrics, _shares)
        raise NotImplementedError
      end

      def increment_for(_operation)
        raise NotImplementedError
      end

      def target_map(_metrics, _provider)
        raise NotImplementedError
      end

      def achievable_gain(shares, targets, total, increment, metrics, selected)
        names = Support.candidates(metrics).map { |item| Support.provider_name(item) }
        names << selected
        names.uniq.map do |name|
          portfolio_gain(shares, targets, total, name, increment).abs
        end.max.to_f
      end

      def portfolio_gain(shares, targets, total, selected, increment)
        names = (targets.keys + shares.keys.map(&:to_s) + [selected]).uniq
        before = distribution_error(names, shares, targets, total)
        projected = shares.transform_keys(&:to_s).transform_values(&:to_f)
        projected[selected] = projected.fetch(selected, 0.0) + increment
        after = distribution_error(names, projected, targets, total + increment)
        before - after
      end

      def distribution_error(names, shares, targets, total)
        names.sum do |name|
          actual = total.positive? ? Support.named_value(shares, name) / total : 0.0
          (actual - targets.fetch(name, 0.0)).abs
        end
      end
    end
  end
end
