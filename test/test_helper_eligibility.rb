# frozen_string_literal: true

require "minitest/autorun"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "route_lens/input_loader"
require "route_lens/eligibility"

module EligibilityTestData
  def provider(overrides = {})
    RouteLens::ProviderState.new(
      {
        "payment_system" => "testpay",
        "status" => "active",
        "traffic_percentage" => 25,
        "limit_amount_min" => 100,
        "limit_amount_max" => 10_000,
        "daily_amount_limit" => 100_000,
        "daily_approved_amount" => 20_000,
        "in_progress_count_limit" => 5,
        "in_progress_count" => 1,
        "in_progress_amount_limit" => 20_000,
        "in_progress_amount" => 1_000,
        "available_requisites" => 2,
        "banks" => ["sberbank", "vtb"],
        "exclude_banks" => false,
        "provider_margin_pct" => 1.0,
        "merchant_margin_pct" => 1.5,
        "allow_negative_agreement" => false
      }.merge(overrides.transform_keys(&:to_s))
    )
  end

  def operation(overrides = {})
    {
      "operation_id" => "op_test",
      "created_at" => "2026-07-30T09:05:00+03:00",
      "amount" => 2_000,
      "bank" => "sberbank"
    }.merge(overrides.transform_keys(&:to_s))
  end
end
