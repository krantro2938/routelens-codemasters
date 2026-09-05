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
end
