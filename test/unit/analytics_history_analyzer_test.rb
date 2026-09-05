# frozen_string_literal: true

require 'csv'
require 'minitest/autorun'
require_relative '../../lib/route_lens/analytics/history_analyzer'

class AnalyticsHistoryAnalyzerTest < Minitest::Test
  def test_analyzes_outcomes_conversion_and_latency_by_provider
    rows = CSV.parse(<<~CSV, headers: true)
      operation_id,created_at,amount,payment_system,status,latency_sec
      op_1,2026-07-29T08:00:00+03:00,100,vipay,approved,10
      op_2,2026-07-29T08:01:00+03:00,300,vipay,rejected,30
      op_3,2026-07-30T09:00:00+03:00,600,payflow,expired,90
    CSV

    result = RouteLens::Analytics::HistoryAnalyzer.new(rows).analyze

    assert_equal '2026-07-29..2026-07-30', result['period']
    assert_equal 3, result['total_operations']
    assert_equal 1_000.0, result['total_amount']
    assert_equal 33.33, result.dig('outcomes', 'approval_rate_pct')
    assert_equal 2, result.dig('providers', 'vipay', 'operations')
    assert_equal 50.0, result.dig('providers', 'vipay', 'approval_rate_pct')
    assert_equal 20.0, result.dig('providers', 'vipay', 'avg_latency_sec')
    assert_equal 20.0, result.dig('providers', 'vipay', 'median_latency_sec')
    assert_equal 30.0, result.dig('providers', 'vipay', 'p95_latency_sec')
  end

  def test_empty_history_is_safe
    result = RouteLens::Analytics::HistoryAnalyzer.new([]).call

    assert_nil result['period']
    assert_equal 0, result['total_operations']
    assert_equal 0.0, result.dig('outcomes', 'approval_rate_pct')
    assert_empty result['providers']
  end
end
