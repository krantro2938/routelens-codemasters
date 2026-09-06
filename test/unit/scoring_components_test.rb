# frozen_string_literal: true

require_relative "../test_helper_scoring"
require "route_lens/scoring/count_target_gain"
require "route_lens/scoring/volume_target_gain"
require "route_lens/scoring/conversion"
require "route_lens/scoring/priority"
require "route_lens/scoring/amount_preference"
require "route_lens/scoring/load"
require "route_lens/scoring/capacity"
require "route_lens/scoring/turnover_obligation"
require "route_lens/scoring/latency"
require "route_lens/scoring/cost"

class ScoringComponentsTest < Minitest::Test
  include ScoringFixtures

  def setup
    @a = provider("a", traffic_percentage: 75, volume_share_pct: 75, priority: 1,
                       avg_latency_sec: 10)
    @b = provider("b", traffic_percentage: 25, volume_share_pct: 25, priority: 3,
                       avg_latency_sec: 90)
    @metrics = {
      providers: [@a, @b],
      count_by_provider: { "a" => 1, "b" => 1 },
      total_count: 2,
      volume_by_provider: { "a" => 100, "b" => 100 },
      total_volume: 200
    }
  end

  def test_count_gain_rewards_assignment_that_improves_portfolio_distribution
    component = RouteLens::Scoring::CountTargetGain.new

    assert_operator component.call(provider: @a, operation: operation, metrics: @metrics), :>, 0
    assert_operator component.call(provider: @b, operation: operation, metrics: @metrics), :<, 0
  end

  def test_count_targets_are_always_interpreted_as_percentages
    one = provider("one", traffic_percentage: 1)
    rest = provider("rest", traffic_percentage: 99)
    metrics = {
      providers: [one, rest], count_by_provider: {}, total_count: 0,
      count_targets: { "one" => 1, "rest" => 99 }
    }
    component = RouteLens::Scoring::CountTargetGain.new

    assert_operator component.call(provider: rest, operation: operation, metrics: metrics), :>,
                    component.call(provider: one, operation: operation, metrics: metrics)
  end

  def test_volume_gain_accounts_for_current_operation_amount
    component = RouteLens::Scoring::VolumeTargetGain.new

    assert_operator component.call(provider: @a, operation: operation(200), metrics: @metrics), :>, 0
    assert_operator component.call(provider: @b, operation: operation(200), metrics: @metrics), :<, 0
  end

  def test_volume_gain_accepts_configuration_targets
    component = RouteLens::Scoring::VolumeTargetGain.new(volume_targets: { "a" => 75, "b" => 25 })
    metrics = @metrics.reject { |key, _value| key == :providers }

    assert_operator component.call(provider: @a, operation: operation(200), metrics: metrics), :>, 0
  end

  def test_volume_target_uses_provider_fallback_for_new_provider
    old = provider("old", volume_share_pct: 0)
    added = provider("added", volume_share_pct: 100)
    component = RouteLens::Scoring::VolumeTargetGain.new(volume_targets: { "old" => 0 })
    metrics = { providers: [old, added], volume_by_provider: {}, total_volume: 0 }

    assert_operator component.call(provider: added, operation: operation, metrics: metrics), :>,
                    component.call(provider: old, operation: operation, metrics: metrics)
  end

  def test_volume_targets_are_always_interpreted_as_percentages
    one = provider("one")
    rest = provider("rest")
    component = RouteLens::Scoring::VolumeTargetGain.new(volume_targets: { "one" => 1, "rest" => 99 })
    metrics = { providers: [one, rest], volume_by_provider: {}, total_volume: 0 }

    assert_operator component.call(provider: rest, operation: operation, metrics: metrics), :>,
                    component.call(provider: one, operation: operation, metrics: metrics)
  end

  def test_direct_quality_components_are_normalized
    assert_in_delta 0.8, RouteLens::Scoring::Conversion.new.call(provider: @a, operation: operation), 0.0001
    assert_in_delta 1.0, RouteLens::Scoring::Priority.new.call(provider: @a, operation: operation,
                                                               metrics: @metrics), 0.0001
    assert_in_delta 0.0, RouteLens::Scoring::Priority.new.call(provider: @b, operation: operation,
                                                               metrics: @metrics), 0.0001
    assert_in_delta 0.0, RouteLens::Scoring::Latency.new.call(provider: @a, operation: operation,
                                                              metrics: @metrics), 0.0001
    assert_in_delta 1.0, RouteLens::Scoring::Latency.new.call(provider: @b, operation: operation,
                                                              metrics: @metrics), 0.0001
    assert_in_delta 0.5, RouteLens::Scoring::Cost.new.call(provider: @a, operation: operation), 0.0001
  end

  def test_conversion_is_normalized_against_the_live_candidate_set
    low = provider("low", conversion_24h: 0.79)
    mid = provider("mid", conversion_24h: 0.87)
    high = provider("high", conversion_24h: 0.91)
    metrics = { eligible_providers: [low, mid, high] }
    component = RouteLens::Scoring::Conversion.new

    assert_in_delta 0.0, component.call(provider: low, operation: operation, metrics: metrics), 0.0001
    assert_in_delta 2.0 / 3.0, component.call(provider: mid, operation: operation, metrics: metrics), 0.0001
    assert_in_delta 1.0, component.call(provider: high, operation: operation, metrics: metrics), 0.0001
  end

  def test_conversion_uses_absolute_reference_when_candidates_are_equal
    twin = provider("twin", conversion_24h: 0.8)
    metrics = { eligible_providers: [twin] }
    component = RouteLens::Scoring::Conversion.new(normalization: { conversion_reference: 1.0 })

    assert_in_delta 0.8, component.call(provider: twin, operation: operation, metrics: metrics), 0.0001
  end

  def test_cost_is_normalized_against_the_live_candidate_set
    cheap = provider("cheap", provider_margin_pct: 0.8, merchant_margin_pct: 1.5)
    mid = provider("mid", provider_margin_pct: 1.0, merchant_margin_pct: 1.5)
    dear = provider("dear", provider_margin_pct: 1.2, merchant_margin_pct: 1.5)
    metrics = { eligible_providers: [cheap, mid, dear] }
    component = RouteLens::Scoring::Cost.new

    assert_in_delta 0.0, component.call(provider: cheap, operation: operation, metrics: metrics), 0.0001
    assert_in_delta 0.5, component.call(provider: mid, operation: operation, metrics: metrics), 0.0001
    assert_in_delta 1.0, component.call(provider: dear, operation: operation, metrics: metrics), 0.0001
  end

  def test_target_gain_scale_does_not_decay_while_the_batch_grows
    component = RouteLens::Scoring::CountTargetGain.new
    early = { providers: [@a, @b], count_by_provider: { "a" => 1, "b" => 1 }, total_count: 2 }
    late = { providers: [@a, @b], count_by_provider: { "a" => 50, "b" => 50 }, total_count: 100 }

    # Сырой выигрыш на сотой операции в 30 раз меньше, чем на второй; после
    # нормализации лучший кандидат остаётся 1.0, а худший -1.0 в обоих случаях.
    assert_in_delta 1.0, component.call(provider: @a, operation: operation, metrics: early), 0.0001
    assert_in_delta 1.0, component.call(provider: @a, operation: operation, metrics: late), 0.0001
    assert_in_delta(-1.0, component.call(provider: @b, operation: operation, metrics: late), 0.0001)
  end

  def test_volume_gain_scale_does_not_decay_while_the_batch_grows
    component = RouteLens::Scoring::VolumeTargetGain.new
    early = { providers: [@a, @b], volume_by_provider: { "a" => 100, "b" => 100 }, total_volume: 200 }
    late = { providers: [@a, @b], volume_by_provider: { "a" => 5_000, "b" => 5_000 }, total_volume: 10_000 }

    assert_in_delta 1.0, component.call(provider: @a, operation: operation(200), metrics: early), 0.0001
    assert_in_delta 1.0, component.call(provider: @a, operation: operation(200), metrics: late), 0.0001
    assert_in_delta(-1.0, component.call(provider: @b, operation: operation(200), metrics: late), 0.0001)
  end

  def test_amount_preference_accepts_half_specified_bands
    only_min = RouteLens::Scoring::AmountPreference.new(preferred_amount_bands: { "a" => { "min" => 50 } })
    only_max = RouteLens::Scoring::AmountPreference.new(preferred_amount_bands: { "a" => { "max" => 150 } })

    # Диапазон без второй границы раньше подставлял Hash#min/#max и падал
    # с NoMethodError на массиве; открытая граница обязана просто не ограничивать.
    assert_equal 1.0, only_min.call(provider: @a, operation: operation(100))
    assert_equal 0.0, only_min.call(provider: @a, operation: operation(10))
    assert_equal 1.0, only_max.call(provider: @a, operation: operation(100))
    assert_equal 0.0, only_max.call(provider: @a, operation: operation(200))
  end

  def test_amount_preference_is_soft_and_configurable
    config = { preferred_amount_bands: { "a" => { min: 50, max: 150 } } }
    component = RouteLens::Scoring::AmountPreference.new(config)

    assert_equal 1.0, component.call(provider: @a, operation: operation(100))
    assert_equal 0.0, component.call(provider: @a, operation: operation(200))
  end

  def test_load_averages_bounded_in_progress_dimensions
    component = RouteLens::Scoring::Load.new

    assert_in_delta 0.2, component.call(provider: @a, operation: operation), 0.0001
  end

  def test_capacity_uses_projected_post_assignment_headroom
    component = RouteLens::Scoring::Capacity.new
    score = component.call(provider: @a, operation: operation(100))

    assert_in_delta((0.8 + 0.7 + 0.6) / 3.0, score, 0.0001)
  end

  def test_unbounded_capacity_is_fully_available
    unbounded = provider("a", daily_amount_limit: nil, in_progress_count_limit: nil,
                              in_progress_amount_limit: nil)

    assert_equal 1.0, RouteLens::Scoring::Capacity.new.call(provider: unbounded, operation: operation)
  end

  def test_turnover_obligation_uses_live_state_override
    config = { daily_turnover_min: { "a" => 1_000 } }
    component = RouteLens::Scoring::TurnoverObligation.new(config)

    assert_in_delta 0.4, component.call(provider: @a, state: { daily_approved_amount: 600 },
                                        operation: operation), 0.0001
    assert_equal 0.0, component.call(provider: @a, state: { daily_approved_amount: 1_100 },
                                     operation: operation)
  end
end
