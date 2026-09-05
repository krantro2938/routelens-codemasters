# frozen_string_literal: true

require "minitest/autorun"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

module ScoringFixtures
  def provider(name, overrides = {})
    {
      "payment_system" => name,
      "traffic_percentage" => 50,
      "volume_share_pct" => 50,
      "priority" => 1,
      "conversion_24h" => 0.8,
      "avg_latency_sec" => 30,
      "provider_margin_pct" => 1.0,
      "merchant_margin_pct" => 2.0,
      "daily_amount_limit" => 1_000,
      "daily_approved_amount" => 100,
      "in_progress_count_limit" => 10,
      "in_progress_count" => 2,
      "in_progress_amount_limit" => 500,
      "in_progress_amount" => 100
    }.merge(overrides.transform_keys(&:to_s))
  end

  def operation(amount = 100)
    { "operation_id" => "op_test", "amount" => amount }
  end
end
