# frozen_string_literal: true

require_relative "../test_helper"
require "route_lens/outcome_simulator"

class OutcomeSimulatorTest < Minitest::Test
  OPERATION = { "operation_id" => "op_test", "amount" => 10_000 }.freeze
  PROVIDER = {
    "payment_system" => "provider_a",
    "conversion_24h" => 0.75,
    "avg_latency_sec" => 40
  }.freeze

  def test_same_seed_produces_same_outcome
    first = RouteLens::OutcomeSimulator.new(seed: 42, mode: "deterministic").call(OPERATION, PROVIDER)
    second = RouteLens::OutcomeSimulator.new(seed: 42, mode: "deterministic").call(OPERATION, PROVIDER)

    assert_equal first, second
  end

  def test_approve_all_mode_is_release_safe
    result = RouteLens::OutcomeSimulator.new.call(OPERATION, PROVIDER)

    assert_equal "approved", result["result"]
    assert_operator result["latency_sec"], :>, 0
  end

  def test_override_wins
    simulator = RouteLens::OutcomeSimulator.new(
      overrides: { "op_test|provider_a" => { "result" => "rejected", "latency_sec" => 7 } }
    )

    assert_equal({ "result" => "rejected", "latency_sec" => 7 }, simulator.call(OPERATION, PROVIDER))
  end
end
