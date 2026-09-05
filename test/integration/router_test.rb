# frozen_string_literal: true

require_relative "../test_helper"
require "route_lens"

class RouterIntegrationTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def setup
    @operations = RouteLens::InputLoader.load_operations(File.join(ROOT, "data/operations_queue_10.json"))
    @policy = RouteLens::Scoring::Policy.load(File.join(ROOT, "config/routing.yml"))
  end

  def test_public_queue_matches_all_deterministic_and_eligible_cases
    result = build_router.route(@operations)
    decisions = result.decisions.to_h { |decision| [decision["operation_id"], decision] }

    assert_equal "quickpay", decisions.dig("op_103", "selected_provider")
    assert_equal "quickpay", decisions.dig("op_104", "selected_provider")
    assert_equal "payflow", decisions.dig("op_107", "selected_provider")
    assert_equal "quickpay", decisions.dig("op_108", "selected_provider")
    assert_equal @operations.length, result.decisions.length
    assert result.decisions.all? { |decision| decision["attempts"].any? }
  end

  def test_rejected_provider_is_released_and_next_candidate_is_selected
    operation = @operations.find { |item| item["operation_id"] == "op_101" }
    simulator = RouteLens::OutcomeSimulator.new(
      overrides: { "op_101|vipay" => { "result" => "rejected", "latency_sec" => 5 } }
    )
    router = build_router(simulator: simulator)
    vipay_before = router.providers.find { |provider| provider.payment_system == "vipay" }.snapshot

    result = router.route([operation])
    decision = result.decisions.first
    vipay_after = router.providers.find { |provider| provider.payment_system == "vipay" }.snapshot

    assert_equal "vipay", decision["routing_sequence"].first
    refute_equal "vipay", decision["selected_provider"]
    assert_equal %w[rejected approved], selected_attempts(decision).map { |attempt| attempt["outcome"] }
    assert_equal vipay_before["daily_approved_amount"], vipay_after["daily_approved_amount"]
    assert_equal vipay_before["in_progress_count"], vipay_after["in_progress_count"]
    assert_equal vipay_before["in_progress_amount"], vipay_after["in_progress_amount"]
    assert_equal vipay_before["available_requisites"], vipay_after["available_requisites"]
    failed_attempt = selected_attempts(decision).first
    assert_equal vipay_before["in_progress_count"] + 1, failed_attempt.dig("state_reserved", "in_progress_count")
    assert_equal vipay_before["available_requisites"] - 1, failed_attempt.dig("state_reserved", "available_requisites")
    assert_includes decision["decision_summary"], "Recovered after 1 failed provider attempt"
    assert_equal 2, result.routing_metrics["total_attempts"]
    assert_equal 1, result.routing_metrics["total_final_assignments"]
    assert_equal({ decision["selected_provider"] => 1 }, result.routing_metrics["final_count_by_provider"])
  end

  def test_reranks_two_external_failures_before_external_success
    operation = @operations.find { |item| item["operation_id"] == "op_101" }
    simulator = RouteLens::OutcomeSimulator.new(
      mode: "approve_all",
      overrides: {
        "op_101|vipay" => { "result" => "rejected", "latency_sec" => 5 },
        "op_101|payflow" => { "result" => "expired", "latency_sec" => 20 }
      }
    )

    decision = build_router(simulator: simulator).route([operation]).decisions.first

    assert_equal %w[vipay payflow quickpay], decision["routing_sequence"]
    assert_equal %w[rejected expired approved], selected_attempts(decision).map { |attempt| attempt["outcome"] }
    assert_equal [1, 2, 3], selected_attempts(decision).map { |attempt| attempt["attempt_number"] }
    assert_equal [false, false, true], selected_attempts(decision).map { |attempt| attempt["final"] }
  end

  def test_external_failure_uses_self_provider_as_last_resort
    operation = @operations.find { |item| item["operation_id"] == "op_103" }
    simulator = RouteLens::OutcomeSimulator.new(
      overrides: { "op_103|quickpay" => { "result" => "expired", "latency_sec" => 90 } }
    )

    decision = build_router(simulator: simulator).route([operation]).decisions.first

    assert_equal "spacepayments", decision["selected_provider"]
    assert_equal %w[quickpay spacepayments], decision["routing_sequence"]
    assert_equal %w[expired approved], selected_attempts(decision).map { |attempt| attempt["outcome"] }
    assert_equal "external_pool_exhausted", selected_attempts(decision).last["reason"]
    assert_operator decision["latency_sec"], :>, 90
  end

  def test_operation_with_no_external_amount_range_uses_fallback_directly
    operation = {
      "operation_id" => "op_fallback",
      "created_at" => "2026-07-30T10:00:00+03:00",
      "amount" => 250_000,
      "bank" => "sberbank"
    }

    decision = build_router.route([operation]).decisions.first

    assert_equal "spacepayments", decision["selected_provider"]
    assert_equal ["spacepayments"], decision["routing_sequence"]
    assert_equal 3, decision["attempts"].count { |attempt| attempt["decision"] == "skipped" }
  end

  private

  def build_router(simulator: RouteLens::OutcomeSimulator.new)
    providers = RouteLens::InputLoader.load_providers(File.join(ROOT, "data/providers.json"))
    RouteLens::Router.new(providers: providers, policy: @policy, simulator: simulator)
  end

  def selected_attempts(decision)
    decision["attempts"].select { |attempt| attempt["decision"] == "selected" }
  end
end
