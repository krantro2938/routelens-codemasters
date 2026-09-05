# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../lib/route_lens/analytics/recommendation_engine'

class AnalyticsRecommendationEngineTest < Minitest::Test
  def setup
    @providers = [
      {
        'payment_system' => 'payflow', 'traffic_percentage' => 35,
        'conversion_24h' => 0.91
      }
    ]
  end

  def test_recommendations_name_numeric_evidence_and_parameters
    engine = RouteLens::Analytics::RecommendationEngine.new(
      providers: @providers,
      distribution: {
        'payflow' => { 'share_pct' => 10, 'target_pct' => 35, 'delta_pct' => -25 }
      },
      projected_daily_utilization: {
        'payflow' => { 'used' => 2_900_000, 'limit' => 3_000_000, 'headroom' => 100_000, 'utilization_pct' => 96.67 }
      },
      provider_metrics: {},
      history: {
        'providers' => {
          'payflow' => { 'operations' => 19, 'approval_rate_pct' => 47.37 }
        }
      },
      skip_reasons_by_provider: {
        'payflow' => { 'daily_amount_limit_exceeded' => 4 }
      }
    )

    messages = engine.generate

    assert messages.any? { |message| message.include?('96.7%') && message.include?('traffic_percentage') }
    assert messages.any? { |message| message.include?('91.0%') && message.include?('47.4%') }
    assert messages.any? { |message| message.include?('hard-excluded 4 times') }
    assert_equal 3, engine.details.length
    assert_equal 10.0, engine.details.first.dig('action', 'proposed')
    assert engine.details.all? { |detail| detail['evidence'].is_a?(Hash) && detail['action'].is_a?(Hash) }
    capacity = engine.details.find { |detail| detail['type'] == 'capacity_pressure' }
    assert_in_delta 100.0, capacity.dig('action', 'target_vector_after').values.sum, 0.001
    conversion = engine.details.find { |detail| detail['type'] == 'conversion_drift' }
    assert_equal 'policy.weights.conversion', conversion.dig('action', 'parameter')
  end
end
