# frozen_string_literal: true

require_relative "../test_helper_scoring"
require "route_lens/scoring/policy"

class ScoringPolicyTest < Minitest::Test
  include ScoringFixtures

  def test_score_returns_auditable_breakdown_and_penalty_direction
    policy = RouteLens::Scoring::Policy.new(
      policy: { name: "test", precision: 4, weights: { conversion: 2, load: 1 } }
    )
    result = policy.score(provider: provider("a"), operation: operation)

    assert_equal "test", result[:policy]
    assert_in_delta 1.4, result[:total], 0.0001
    assert_equal(-1.0, result.dig(:breakdown, "load", :direction))
    assert_equal %i[priority latency_sec provider], result[:tie_break].keys
    assert_equal(-result[:total], result[:sort_key].first)
  end

  # Полный путь скоринга на односторонней полосе сумм: раньше отсутствующая
  # граница подставляла Hash#min/#max, и ранжирование падало с NoMethodError
  # уже внутри rank, а не в изолированном компоненте.
  def test_rank_survives_half_specified_preferred_amount_bands
    policy = RouteLens::Scoring::Policy.new(
      policy: { name: "bands", weights: { amount_preference: 1 } },
      preferred_amount_bands: { "a" => { "min" => 50 }, "b" => { "max" => 150 } }
    )
    candidates = [provider("a"), provider("b")]

    ranking = policy.rank(candidates: candidates, operation: operation(100))

    assert_equal 2, ranking.length
    assert(ranking.all? { |entry| entry.dig(:result, :breakdown, "amount_preference", :raw) == 1.0 })
    assert_equal 1.0, policy.score(provider: provider("a"), operation: operation(1_000))[:total]
    assert_equal 0.0, policy.score(provider: provider("a"), operation: operation(10))[:total]
    assert_equal 0.0, policy.score(provider: provider("b"), operation: operation(1_000))[:total]
  end

  def test_rank_uses_score_then_priority_latency_and_name
    policy = RouteLens::Scoring::Policy.new(policy: { weights: { conversion: 1 } })
    slow_priority_one = provider("z", conversion_24h: 0.9, priority: 1, avg_latency_sec: 90)
    fast_priority_one = provider("a", conversion_24h: 0.9, priority: 1, avg_latency_sec: 10)
    priority_two = provider("b", conversion_24h: 0.9, priority: 2, avg_latency_sec: 1)

    ranking = policy.rank(candidates: [priority_two, slow_priority_one, fast_priority_one],
                          operation: operation)

    assert_equal %w[a z b], ranking.map { |entry| entry[:provider]["payment_system"] }
  end

  def test_rank_passes_provider_specific_state
    policy = RouteLens::Scoring::Policy.new(policy: { weights: { load: 1 } })
    a = provider("a")
    b = provider("b")
    states = {
      "a" => { in_progress_count: 9, in_progress_amount: 450 },
      "b" => { in_progress_count: 1, in_progress_amount: 50 }
    }

    ranking = policy.rank(candidates: [a, b], states: states, operation: operation)

    assert_equal "b", ranking.first[:provider]["payment_system"]
  end

  def test_loads_repository_configuration
    path = File.expand_path("../../config/routing.yml", __dir__)
    policy = RouteLens::Scoring::Policy.load(path)

    assert_equal "balanced_v2", policy.name
    assert_equal 10, policy.weights.length
    assert_equal %w[capacity_first cascade conversion_first], policy.available_presets
  end

  def test_loads_named_preset_and_policy_volume_targets
    path = File.expand_path("../../config/routing.yml", __dir__)
    policy = RouteLens::Scoring::Policy.load(path, preset: "cascade")

    assert_equal "cascade", policy.name
    assert_equal({ "priority" => 4.0, "conversion" => 0.25 }, policy.weights)
    assert_equal 50.0, policy.volume_target_for(provider("vipay"))
    assert_equal "policy.volume_targets", policy.volume_target_source_for(provider("vipay"))
    assert_raises(ArgumentError) { RouteLens::Scoring::Policy.load(path, preset: "missing") }
  end

  def test_rejects_unknown_or_negative_weights
    error = assert_raises(ArgumentError) do
      RouteLens::Scoring::Policy.new(policy: { weights: { mystery: 1 } })
    end
    assert_match(/unknown scoring components/, error.message)

    assert_raises(ArgumentError) do
      RouteLens::Scoring::Policy.new(policy: { weights: { conversion: -1 } })
    end
  end

  def test_rejects_invalid_volume_targets
    assert_raises(ArgumentError) do
      RouteLens::Scoring::Policy.new(
        policy: { weights: { volume_target_gain: 1 } },
        volume_targets: { "provider" => 101 }
      )
    end
  end

  def test_rejects_target_vectors_that_do_not_sum_to_one_hundred
    # Каждое значение по отдельности выглядит корректным процентом, поэтому
    # вектор проверяется целиком: 150% делает цели недостижимыми.
    error = assert_raises(ArgumentError) do
      RouteLens::Scoring::Policy.new(
        policy: { weights: { volume_target_gain: 1 } },
        volume_targets: { "vipay" => 100, "payflow" => 25, "quickpay" => 25 }
      )
    end
    assert_match(/volume targets must sum to 100/, error.message)
    assert_match(/150/, error.message)

    count_error = assert_raises(ArgumentError) do
      RouteLens::Scoring::Policy.new(
        policy: { weights: { count_target_gain: 1 } },
        traffic_targets: { "vipay" => 40, "payflow" => 35 }
      )
    end
    assert_match(/count targets must sum to 100/, count_error.message)
  end

  def test_accepts_target_vectors_within_the_rounding_tolerance
    policy = RouteLens::Scoring::Policy.new(
      policy: { name: "rounded", weights: { volume_target_gain: 1 } },
      volume_targets: { "a" => 33.3, "b" => 33.3, "c" => 33.3 }
    )

    assert_equal "rounded", policy.name
  end

  def test_rejects_invalid_precision_and_non_object_target_sections
    assert_match(/precision/, assert_raises(ArgumentError) do
      RouteLens::Scoring::Policy.new(policy: { precision: -1, weights: { conversion: 1 } })
    end.message)

    assert_match(/volume targets must be an object/, assert_raises(ArgumentError) do
      RouteLens::Scoring::Policy.new(
        policy: { weights: { conversion: 1 } }, volume_targets: "vipay: 100"
      )
    end.message)
  end

  def test_rejects_malformed_preferred_amount_bands
    assert_match(/must be an object/, assert_raises(ArgumentError) do
      RouteLens::Scoring::Policy.new(
        policy: { weights: { amount_preference: 1 } }, preferred_amount_bands: { "vipay" => "50..100" }
      )
    end.message)

    error = assert_raises(ArgumentError) do
      RouteLens::Scoring::Policy.new(
        policy: { weights: { amount_preference: 1 } },
        preferred_amount_bands: { "vipay" => { min: 100, max: 50 } }
      )
    end
    assert_match(/min cannot exceed max/, error.message)

    assert_match(/finite number/, assert_raises(ArgumentError) do
      RouteLens::Scoring::Policy.new(
        policy: { weights: { amount_preference: 1 } },
        preferred_amount_bands: { "vipay" => { min: "cheap" } }
      )
    end.message)
  end

  def test_rejects_invalid_turnover_and_normalization_values
    assert_match(/daily_turnover_min\.vipay cannot be negative/, assert_raises(ArgumentError) do
      RouteLens::Scoring::Policy.new(
        policy: { weights: { turnover_obligation: 1 } }, daily_turnover_min: { "vipay" => -1 }
      )
    end.message)

    assert_match(/greater than zero/, assert_raises(ArgumentError) do
      RouteLens::Scoring::Policy.new(
        policy: { weights: { latency: 1 } }, normalization: { latency_reference_sec: 0 }
      )
    end.message)

    assert_match(/finite number/, assert_raises(ArgumentError) do
      RouteLens::Scoring::Policy.new(
        policy: { weights: { cost: 1 } }, normalization: { cost_reference_pct: "normal" }
      )
    end.message)
  end
end
