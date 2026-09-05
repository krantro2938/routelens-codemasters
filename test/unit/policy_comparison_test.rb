# frozen_string_literal: true

require_relative "../test_helper"
require "route_lens"
require "route_lens/analytics/history_analyzer"

class PolicyComparisonTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def test_compares_presets_and_replays_a_complete_target_vector
    snapshot = RouteLens::InputLoader.load_provider_snapshot(File.join(ROOT, "data/providers.json"))
    operations = RouteLens::InputLoader.load_operations(File.join(ROOT, "data/operations_queue_10.json"))
    history = RouteLens::Analytics::HistoryAnalyzer.new(
      RouteLens::InputLoader.load_history(File.join(ROOT, "data/operations_history.csv"))
    ).analyze

    result = RouteLens::PolicyComparison.new(
      provider_snapshot: snapshot,
      operations: operations,
      policy_config: File.join(ROOT, "config/routing.yml"),
      history: history
    ).build

    assert_equal %w[balanced conversion_first cascade capacity_first], result["scenarios"].map { |item| item["name"] }
    assert result["scenarios"].any? { |item| item["changed_operations_vs_balanced"].any? }
    after = result.dig("recommendation_replay", "after")
    assert_in_delta 100.0, after.fetch("traffic_targets").values.sum, 0.001
    assert_operator after.fetch("count_target_error_pp"), :<,
                    result.dig("recommendation_replay", "before", "count_target_error_pp")
    assert_equal "payflow", result.dig("recommendation_replay", "tradeoffs", "constrained_provider")
    assert result.dig("recommendation_replay", "tradeoffs").key?("capacity_utilization_change_pp")
  end
end
