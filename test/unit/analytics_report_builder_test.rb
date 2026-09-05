# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../lib/route_lens/analytics/report_builder'
require_relative '../../lib/route_lens/scoring/policy'

class AnalyticsReportBuilderTest < Minitest::Test
  def providers
    {
      'snapshot_at' => '2026-07-30T09:00:00+03:00',
      'providers' => [
        provider('vipay', 50, 0.80, 1_000, 400),
        provider('payflow', 30, 0.90, 1_000, 900),
        provider('quickpay', 20, 0.70, 2_000, 100),
        provider('spacepayments', 0, 0.95, nil, 0)
      ]
    }
  end

  def provider(name, target, conversion, limit, used)
    {
      'payment_system' => name,
      'traffic_percentage' => target,
      'conversion_24h' => conversion,
      'daily_amount_limit' => limit,
      'daily_approved_amount' => used,
      'in_progress_count' => 0,
      'in_progress_amount' => 0
    }
  end

  def operations
    (1..4).map do |number|
      {
        'operation_id' => "op_#{number}", 'created_at' => "2026-07-30T09:0#{number}:00+03:00", 'amount' => 100
      }
    end
  end

  def decisions
    [
      decision('op_1', 'vipay', 'approved', 10, [attempt('vipay', 'selected')]),
      decision('op_2', 'quickpay', 'approved', 20, [
        attempt('payflow', 'selected', 'rejected'),
        attempt('vipay', 'skipped', nil, 'bank_not_in_list'),
        attempt('quickpay', 'selected', 'approved')
      ]),
      decision('op_3', 'spacepayments', 'expired', 30, [attempt('spacepayments', 'selected')]),
      decision('op_4', 'quickpay', 'rejected', 50, [
        attempt('payflow', 'skipped', nil, 'lower_policy_score'),
        attempt('quickpay', 'selected')
      ])
    ]
  end

  def decision(id, selected, result, latency, attempts)
    {
      'operation_id' => id, 'selected_provider' => selected,
      'simulated_result' => result, 'latency_sec' => latency, 'attempts' => attempts
    }
  end

  def attempt(provider, decision, outcome = nil, reason = nil)
    result = { 'provider' => provider, 'decision' => decision, 'reason' => reason || 'ranked_candidate' }
    result['outcome'] = outcome unless outcome.nil?
    result
  end

  def final_state
    {
      'providers' => [
        provider('vipay', 50, 0.80, 1_000, 500),
        provider('payflow', 30, 0.90, 1_000, 960),
        provider('quickpay', 20, 0.70, 2_000, 200),
        provider('spacepayments', 0, 0.95, nil, 0)
      ]
    }
  end

  def history
    {
      'providers' => {
        'payflow' => { 'operations' => 20, 'approval_rate_pct' => 50.0 }
      }
    }
  end

  def test_builds_required_and_extended_report_metrics
    report = RouteLens::Analytics::ReportBuilder.new(
      providers: providers,
      operations: operations,
      decisions: decisions,
      final_state: final_state,
      history: history
    ).build

    assert_equal '2026-07-30', report['period']
    assert_equal 4, report['total_operations']
    assert_equal 400.0, report['total_amount']
    assert_equal 2, report.dig('distribution', 'quickpay', 'count')
    assert_equal 50.0, report.dig('distribution', 'quickpay', 'share_pct')
    assert_equal 30.0, report.dig('distribution', 'quickpay', 'delta_pct')
    assert_equal 50.0, report.dig('volume_distribution', 'quickpay', 'share_pct')
    assert_equal 2, report.dig('outcomes', 'approved', 'count')
    assert_equal 50.0, report.dig('outcomes', 'approval_rate_pct')
    assert_equal 27.5, report.dig('latency', 'avg_sec')
    assert_equal 50.0, report.dig('latency', 'p95_sec')
    assert_equal 1, report.dig('skip_reasons', 'bank_not_in_list')
    refute report['skip_reasons'].key?('lower_policy_score')
    assert_equal 1, report.dig('policy_nonselections', 'total')
    assert_equal 1, report.dig('policy_nonselections', 'reasons', 'lower_policy_score')
    assert_equal 1, report.dig('policy_nonselections', 'by_provider', 'payflow', 'lower_policy_score')
    assert_equal 1, report['retry_count']
    assert_equal 1, report['fallback_count']
    assert_equal 5, report.dig('attempt_outcomes', 'total_attempts')
    assert_equal 2, report.dig('attempt_outcomes', 'rejected')
    assert_equal 1, report.dig('attempt_outcomes', 'recovered_operations')
    assert_equal 33.33, report.dig('attempt_outcomes', 'recovery_rate_pct')
    assert_equal 1, report.dig('provider_metrics', 'payflow', 'attempt_outcomes', 'rejected')
    assert_equal 960.0, report.dig('projected_daily_utilization', 'payflow', 'used')
    assert_equal 96.0, report.dig('projected_daily_utilization', 'payflow', 'utilization_pct')
    assert_equal 50.0, report.dig('provider_metrics', 'quickpay', 'approval_rate_pct')
    refute_empty report['unmet_goals']
    refute report['unmet_goals'].any? { |goal| goal['provider'] == 'quickpay' }
    assert report['recommendations'].any? { |recommendation| recommendation.include?('payflow daily limit') }
    assert report['recommendations'].any? { |recommendation| recommendation.include?('conversion_24h') }
    payflow_share_recommendation = report['recommendations'].find do |recommendation|
      recommendation.start_with?('payflow count share')
    end
    refute_nil payflow_share_recommendation
    refute_includes payflow_share_recommendation, 'hard-excluded'
    assert_equal report['projected_daily_utilization'], report['capacity_utilization']
  end

  def test_uses_active_policy_volume_targets
    policy = RouteLens::Scoring::Policy.new(
      'policy' => { 'name' => 'test', 'weights' => { 'volume_target_gain' => 1 } },
      'volume_targets' => { 'vipay' => 60, 'payflow' => 25, 'quickpay' => 15 }
    )
    report = RouteLens::Analytics::ReportBuilder.new(
      providers: providers, operations: operations, decisions: decisions, history: {}, policy: policy
    ).build

    assert_equal 60.0, report.dig('volume_distribution', 'vipay', 'target_pct')
    assert_equal 'policy.volume_targets', report.dig('volume_distribution', 'vipay', 'target_source')
    assert_equal({ 'vipay' => 60.0, 'payflow' => 25.0, 'quickpay' => 15.0 }, report.dig('policy', 'volume_targets'))
  end

  def test_derives_projected_daily_usage_when_final_state_is_absent
    report = RouteLens::Analytics::ReportBuilder.new(
      providers: providers,
      operations: operations,
      decisions: decisions,
      history: {}
    ).call

    assert_equal 500.0, report.dig('projected_daily_utilization', 'vipay', 'used')
    assert_equal 200.0, report.dig('projected_daily_utilization', 'quickpay', 'used')
    assert_nil report.dig('projected_daily_utilization', 'spacepayments', 'utilization_pct')
  end

  def test_empty_batch_does_not_divide_by_zero
    report = RouteLens::Analytics::ReportBuilder.new(
      providers: providers, operations: [], decisions: [], history: {}
    ).build

    assert_equal 0, report['total_operations']
    assert_equal 0.0, report.dig('distribution', 'vipay', 'share_pct')
    assert_equal 0.0, report.dig('outcomes', 'approval_rate_pct')
    assert_equal 0.0, report.dig('latency', 'p95_sec')
  end
end
