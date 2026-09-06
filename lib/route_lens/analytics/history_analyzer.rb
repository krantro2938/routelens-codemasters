# frozen_string_literal: true

require 'csv'
require_relative 'support'

module RouteLens
  module Analytics
    # Агрегирует исторический CSV отдельно от текущего состояния. Текущая
    # конверсия и исторический approval rate не смешиваются: разница между
    # окнами используется как сигнал дрейфа метрики.
    class HistoryAnalyzer
      STATUSES = %w[approved rejected expired].freeze

      def self.from_csv(path, **options)
        new(CSV.read(path, headers: true), **options)
      end

      def initialize(rows)
        collection = rows.respond_to?(:each) ? rows.each.to_a : Array(rows)
        @rows = collection.map { |row| Support.hash(row) }
      end

      def analyze
        {
          'period' => Support.period(@rows.map { |row| Support.fetch(row, 'created_at') }),
          'total_operations' => @rows.length,
          'total_amount' => Support.round(@rows.sum { |row| Support.number(Support.fetch(row, 'amount')) }),
          'outcomes' => outcome_metrics(@rows),
          'providers' => provider_metrics
        }
      end
      alias call analyze

      private

      def outcome_metrics(rows)
        total = rows.length
        result = STATUSES.to_h do |status|
          matching = rows.select { |row| Support.fetch(row, 'status').to_s == status }
          [status, {
            'count' => matching.length,
            'share_pct' => Support.percent(matching.length, total),
            'amount' => Support.round(matching.sum { |row| Support.number(Support.fetch(row, 'amount')) })
          }]
        end
        result['approval_rate_pct'] = Support.percent(result.dig('approved', 'count'), total)
        result['failure_rate_pct'] = Support.percent(
          result.dig('rejected', 'count').to_i + result.dig('expired', 'count').to_i,
          total
        )
        result
      end

      def provider_metrics
        # Доли count/volume считаются здесь же: они показывают, достигались ли
        # целевые traffic_percentage хоть когда-нибудь, а не только сегодня.
        total_operations = @rows.length
        total_amount = @rows.sum { |row| Support.number(Support.fetch(row, 'amount')) }
        @rows.group_by { |row| Support.fetch(row, 'payment_system').to_s }
             .reject { |name, _rows| name.empty? }
             .sort.to_h do |name, rows|
          latencies = rows.filter_map do |row|
            value = Support.fetch(row, 'latency_sec')
            Support.number(value) unless value.nil? || value == ''
          end
          outcomes = outcome_metrics(rows)
          amount = rows.sum { |row| Support.number(Support.fetch(row, 'amount')) }
          [name, {
            'operations' => rows.length,
            'amount' => Support.round(amount),
            'count_share_pct' => Support.percent(rows.length, total_operations),
            'volume_share_pct' => Support.percent(amount, total_amount),
            'approved_count' => outcomes.dig('approved', 'count'),
            'rejected_count' => outcomes.dig('rejected', 'count'),
            'expired_count' => outcomes.dig('expired', 'count'),
            'approval_rate_pct' => outcomes['approval_rate_pct'],
            'avg_latency_sec' => Support.average(latencies),
            'median_latency_sec' => Support.median(latencies),
            'p95_latency_sec' => Support.percentile(latencies, 0.95)
          }]
        end
      end
    end
  end
end
