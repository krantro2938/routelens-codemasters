# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../lib/route_lens/analytics/recommendation_engine'

class AnalyticsRecommendationEngineTest < Minitest::Test
  def setup
    @providers = [
      {
        'payment_system' => 'payflow', 'traffic_percentage' => 35,
        'conversion_24h' => 0.91, 'limit_amount_max' => 50_000,
        'daily_amount_limit' => 3_000_000
      }
    ]
  end

  def policy(weights)
    Struct.new(:weights).new(weights)
  end

  def engine(overrides = {})
    RouteLens::Analytics::RecommendationEngine.new(**{
      providers: @providers,
      distribution: {
        'payflow' => { 'count' => 2, 'share_pct' => 10, 'target_pct' => 35, 'delta_pct' => -25 },
        'spacepayments' => { 'count' => 18, 'share_pct' => 90, 'target_pct' => 0, 'delta_pct' => 90 }
      },
      projected_daily_utilization: {
        'payflow' => { 'used' => 2_900_000, 'limit' => 3_000_000, 'headroom' => 100_000, 'utilization_pct' => 96.67 }
      },
      provider_metrics: {
        'payflow' => {
          'blocked_operations' => {
            'operations' => 12,
            'reasons' => {
              'amount_exceeds_limit' => {
                'operations' => 12, 'amount_sum' => 1_200_000, 'amount_p10' => 60_000, 'amount_p90' => 140_000
              }
            }
          }
        }
      },
      history: {
        'total_operations' => 100,
        'period' => '2026-07-29',
        'providers' => {
          'payflow' => { 'operations' => 19, 'approval_rate_pct' => 47.37, 'count_share_pct' => 19.0,
                         'volume_share_pct' => 8.48 }
        }
      },
      skip_reasons_by_provider: { 'payflow' => { 'amount_exceeds_limit' => 12 } },
      policy: policy('conversion' => 1.5, 'count_target_gain' => 2.5),
      total_operations: 20
    }.merge(overrides))
  end

  def test_recommendations_name_numeric_evidence_and_parameters
    subject = engine
    messages = subject.generate

    assert messages.any? { |message| message.include?('96.7%') && message.include?('traffic_percentage') }
    assert messages.any? { |message| message.include?('91.0%') && message.include?('47.4%') }
    assert subject.details.all? { |detail| detail['evidence'].is_a?(Hash) && detail['action'].is_a?(Hash) }
    capacity = subject.details.find { |detail| detail['type'] == 'capacity_pressure' }
    assert_equal 10.0, capacity.dig('action', 'proposed')
    assert_in_delta 100.0, capacity.dig('action', 'target_vector_after').values.sum, 0.001
    conversion = subject.details.find { |detail| detail['type'] == 'conversion_drift' }
    assert_equal 'policy.weights.conversion', conversion.dig('action', 'parameter')
  end

  # Русская форма числительного вместо "1 times".
  def test_messages_use_russian_plural_forms
    messages = engine(total_operations: 20).generate
    infeasible = messages.find { |message| message.include?('amount_exceeds_limit') }

    assert_includes infeasible, '12 операций'
    refute infeasible.include?('times')
  end

  # Ни одна рекомендация не имеет права предлагать то, что уже установлено.
  def test_no_recommendation_proposes_the_current_value
    details = engine.tap(&:generate).details + engine(total_operations: 3).tap(&:generate).details

    refute_empty details
    details.each do |detail|
      action = detail['action']
      refute_equal action['current'], action['proposed'], "#{detail['type']} предлагает текущее значение"
    end
  end

  def test_hard_constraint_gap_names_the_blocking_rule_and_a_numeric_parameter
    details = engine.tap(&:generate).details
    infeasible = details.find { |detail| detail['type'] == 'infeasible_count_target' }

    refute_nil infeasible
    assert_equal 'amount_exceeds_limit', infeasible.dig('evidence', 'blocking_rule')
    assert_equal 'limit_amount_max', infeasible.dig('action', 'parameter')
    assert_equal 50_000, infeasible.dig('action', 'current')
    assert_equal 140_000.0, infeasible.dig('action', 'proposed')
    assert_equal 35.0, infeasible.dig('action', 'alternative', 'current')
    assert_equal 10.0, infeasible.dig('action', 'alternative', 'proposed')
  end

  # Без жёстких исключений отклонение объясняется скорингом, а не правилами.
  def test_soft_deviation_proposes_a_policy_weight_change
    details = engine(provider_metrics: {}, skip_reasons_by_provider: {}).tap(&:generate).details
    deviation = details.find { |detail| detail['type'] == 'count_share_below_target' }

    refute_nil deviation
    assert_equal 'policy.weights.count_target_gain', deviation.dig('action', 'parameter')
    assert_equal 3.75, deviation.dig('action', 'proposed')
    assert_equal 'low', deviation.dig('evidence', 'confidence')
    assert_includes deviation['message'], 'n=20'
  end

  def test_small_sample_suppresses_share_deviation_claims
    details = engine(total_operations: 3).tap(&:generate).details
    types = details.map { |detail| detail['type'] }

    refute_includes types, 'infeasible_count_target'
    refute_includes types, 'count_share_below_target'
    guard = details.find { |detail| detail['type'] == 'insufficient_sample' }
    refute_nil guard
    assert_equal 3, guard.dig('evidence', 'operations')
    assert_equal 3, guard.dig('action', 'current')
    assert_equal 10, guard.dig('action', 'proposed')
    assert_includes guard['message'], '3 операции'
  end

  # История используется для калибровки, а не только как справка.
  def test_history_produces_a_calibrated_conversion_parameter
    details = engine.tap(&:generate).details
    calibration = details.find { |detail| detail['type'] == 'conversion_calibration' }

    refute_nil calibration
    assert_equal 'providers.payflow.conversion_24h', calibration.dig('action', 'parameter')
    assert_equal 0.91, calibration.dig('action', 'current')
    assert_equal 0.697, calibration.dig('action', 'proposed')
    assert_equal 19, calibration.dig('evidence', 'historical_operations')

    gap = details.find { |detail| detail['type'] == 'historical_target_gap' }
    refute_nil gap
    assert_equal 19.0, gap.dig('action', 'proposed')
    assert_equal(-16.0, gap.dig('evidence', 'delta_pct'))
  end

  # Насыщение пула: снижать доли некуда, поэтому советуется поднять ёмкость.
  def test_pool_saturation_outranks_and_replaces_capacity_advice
    providers = %w[vipay payflow quickpay].map do |name|
      { 'payment_system' => name, 'traffic_percentage' => 30, 'conversion_24h' => 0.9 }
    end
    utilization = {
      'vipay' => { 'used' => 4_999_000, 'limit' => 5_000_000, 'headroom' => 1_000, 'utilization_pct' => 99.98 },
      'payflow' => { 'used' => 2_999_000, 'limit' => 3_000_000, 'headroom' => 1_000, 'utilization_pct' => 99.97 },
      'quickpay' => { 'used' => 7_998_000, 'limit' => 8_000_000, 'headroom' => 2_000, 'utilization_pct' => 99.98 }
    }
    subject = RouteLens::Analytics::RecommendationEngine.new(
      providers: providers,
      distribution: { 'spacepayments' => { 'count' => 851, 'share_pct' => 85.1, 'target_pct' => 0, 'delta_pct' => 85.1 } },
      projected_daily_utilization: utilization,
      provider_metrics: { 'spacepayments' => { 'amount' => 60_000_000 } },
      resilience: { 'fallback_count' => 851, 'fallback_share_pct' => 85.1 },
      total_operations: 1_000
    )
    subject.generate

    types = subject.details.map { |detail| detail['type'] }
    assert_equal 'pool_saturation', types.first
    refute_includes types, 'capacity_pressure'
    saturation = subject.details.first
    assert_equal 'daily_amount_limit', saturation.dig('action', 'parameter')
    assert_equal 16_000_000.0, saturation.dig('action', 'current')
    assert_equal 76_000_000.0, saturation.dig('action', 'proposed')
    assert_equal %w[vipay payflow quickpay], saturation.dig('evidence', 'saturated_providers')
    refute_includes saturation['message'], 'снизить traffic_percentage'
  end
end
