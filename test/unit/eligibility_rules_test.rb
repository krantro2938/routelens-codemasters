# frozen_string_literal: true

require_relative "../test_helper_eligibility"

class EligibilityRulesTest < Minitest::Test
  include EligibilityTestData

  def evaluate(rule, provider_overrides = {}, operation_overrides = {}, context: {})
    rule.new.evaluate(provider(provider_overrides), operation(operation_overrides), context: context)
  end

  def test_status_rule_rejects_inactive_provider
    result = evaluate(RouteLens::Eligibility::StatusRule, { status: "maintenance" })
    assert_equal "provider_inactive", result.reason
  end

  def test_amount_boundaries_are_inclusive
    rule = RouteLens::Eligibility::AmountRule
    assert evaluate(rule, {}, { amount: 100 }).eligible?
    assert evaluate(rule, {}, { amount: 10_000 }).eligible?
    assert_equal "amount_below_minimum", evaluate(rule, {}, { amount: 99 }).reason
    assert_equal "amount_exceeds_limit", evaluate(rule, {}, { amount: 10_001 }).reason
  end

  def test_nil_amount_boundaries_are_unbounded
    result = evaluate(
      RouteLens::Eligibility::AmountRule,
      { limit_amount_min: nil, limit_amount_max: nil },
      { amount: 1_000_000 }
    )
    assert result.eligible?
  end

  def test_daily_limit_uses_prospective_approved_amount
    rule = RouteLens::Eligibility::DailyAmountRule
    assert evaluate(rule, { daily_approved_amount: 98_000 }, { amount: 2_000 }).eligible?
    assert_equal "daily_amount_limit_exceeded",
                 evaluate(rule, { daily_approved_amount: 98_001 }, { amount: 2_000 }).reason
  end

  def test_in_progress_limits_include_new_operation
    count_rule = RouteLens::Eligibility::InProgressCountRule
    amount_rule = RouteLens::Eligibility::InProgressAmountRule
    assert evaluate(count_rule, { in_progress_count: 4 }).eligible?
    assert_equal "in_progress_count_limit_exceeded", evaluate(count_rule, { in_progress_count: 5 }).reason
    assert evaluate(amount_rule, { in_progress_amount: 18_000 }, { amount: 2_000 }).eligible?
    assert_equal "in_progress_amount_limit_exceeded",
                 evaluate(amount_rule, { in_progress_amount: 18_001 }, { amount: 2_000 }).reason
  end

  def test_bank_allowlist_and_denylist
    rule = RouteLens::Eligibility::BankRule
    assert_equal "bank_not_in_list", evaluate(rule, {}, { bank: "alfa" }).reason
    assert evaluate(rule, { banks: [] }, { bank: "alfa" }).eligible?
    assert_equal "bank_excluded",
                 evaluate(rule, { banks: ["sberbank"], exclude_banks: true }).reason
    assert evaluate(rule, { banks: ["vtb"], exclude_banks: true }).eligible?
  end

  def test_bank_comparison_matches_official_validator_exactly
    result = evaluate(RouteLens::Eligibility::BankRule, { banks: ["SBERBANK"] })
    assert_equal "bank_not_in_list", result.reason
  end

  def test_margin_rule_honors_negative_agreement
    rule = RouteLens::Eligibility::MarginRule
    expensive = { provider_margin_pct: 2.0, merchant_margin_pct: 1.5 }
    assert_equal "negative_margin_not_allowed", evaluate(rule, expensive).reason
    assert evaluate(rule, expensive.merge(allow_negative_agreement: true)).eligible?
  end

  def test_requisites_must_be_positive
    assert_equal "no_available_requisites",
                 evaluate(RouteLens::Eligibility::RequisitesRule, { available_requisites: 0 }).reason
  end

  def test_rate_limit_checks_prospective_request
    rule = RouteLens::Eligibility::RateLimitRule
    settings = { requests_per_minute_limit: 3, requests_last_minute: 2 }
    assert evaluate(rule, settings).eligible?
    assert_equal "rate_limit_exceeded", evaluate(rule, settings, {}, context: { requests_per_minute: 3 }).reason
  end

  def test_self_provider_requires_fallback_context
    state = provider(payment_system: "spacepayments", traffic_percentage: 0, banks: [])
    rule = RouteLens::Eligibility::SelfProviderRule.new
    assert_equal "self_provider_reserved_for_fallback", rule.evaluate(state, operation).reason
    assert rule.evaluate(state, operation, context: { fallback: true }).eligible?
  end

  def test_zero_traffic_disables_external_provider
    result = evaluate(RouteLens::Eligibility::TrafficEnabledRule, { traffic_percentage: 0 })
    assert_equal "traffic_disabled", result.reason
  end
end
