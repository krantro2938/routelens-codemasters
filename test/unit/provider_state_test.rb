# frozen_string_literal: true

require_relative "../test_helper_eligibility"

class ProviderStateTest < Minitest::Test
  include EligibilityTestData

  def test_reserve_and_approve_update_counters
    state = provider
    request_time = Time.iso8601("2026-07-30T09:05:00+03:00")
    state.reserve!(2_000, reservation_id: "op_1", at: request_time)
    assert_equal 2, state["in_progress_count"]
    assert_equal 3_000, state["in_progress_amount"]
    assert_equal 1, state["available_requisites"]
    assert_equal 1, state.requests_per_minute(at: request_time)

    state.approve!(reservation_id: "op_1")
    assert_equal 1, state["in_progress_count"]
    assert_equal 1_000, state["in_progress_amount"]
    assert_equal 2, state["available_requisites"]
    assert_equal 22_000, state["daily_approved_amount"]
  end

  def test_reject_and_expire_release_without_approved_turnover
    state = provider
    state.reserve!(500, reservation_id: "rejected")
    state.reject!(reservation_id: "rejected")
    state.reserve!(700, reservation_id: "expired")
    state.expire!(reservation_id: "expired")

    assert_equal 1, state["in_progress_count"]
    assert_equal 1_000, state["in_progress_amount"]
    assert_equal 20_000, state["daily_approved_amount"]
  end

  def test_reservation_rejects_capacity_overrun_without_partial_mutation
    state = provider(in_progress_count: 5)
    assert_raises(RouteLens::CapacityExceeded) { state.reserve!(2_000) }
    assert_equal 5, state["in_progress_count"]
    assert_equal 1_000, state["in_progress_amount"]
  end

  def test_reservation_rejects_when_no_requisites_are_free
    state = provider(available_requisites: 0)
    assert_raises(RouteLens::CapacityExceeded) { state.reserve!(2_000) }
    assert_equal 0, state["available_requisites"]
  end

  def test_unknown_and_duplicate_reservations_are_rejected
    state = provider
    state.reserve!(500, reservation_id: "op")
    assert_raises(RouteLens::StateError) { state.reserve!(500, reservation_id: "op") }
    assert_raises(RouteLens::UnknownReservation) { state.release!(reservation_id: "missing") }
  end

  def test_snapshot_is_defensive_copy
    state = provider
    snapshot = state.to_h
    snapshot["banks"] << "alfa"
    refute_includes state["banks"], "alfa"
  end

  def test_rate_counter_is_scoped_to_minute
    state = provider(requests_last_minute: 2)
    first_minute = Time.iso8601("2026-07-30T09:05:00+03:00")
    next_minute = Time.iso8601("2026-07-30T09:06:00+03:00")
    state.record_request!(at: first_minute)
    assert_equal 3, state.requests_per_minute(at: first_minute)
    assert_equal 0, state.requests_per_minute(at: next_minute)
  end

  def test_rate_counter_retains_each_minute_when_operations_are_out_of_order
    state = provider(requests_per_minute_limit: 2)
    first_minute = Time.iso8601("2026-07-30T09:05:00+03:00")
    next_minute = Time.iso8601("2026-07-30T09:06:00+03:00")

    state.record_request!(at: first_minute)
    state.record_request!(at: next_minute)
    state.record_request!(at: first_minute)

    assert_equal 2, state.requests_per_minute(at: first_minute)
    assert_equal 1, state.requests_per_minute(at: next_minute)
    assert_raises(RouteLens::CapacityExceeded) do
      state.reserve!(500, reservation_id: "third-in-first-minute", at: first_minute)
    end
  end

  def test_snapshot_rate_baseline_applies_only_to_first_observed_minute
    state = provider(requests_per_minute_limit: 3, current_requests_per_minute: 2)
    first_minute = Time.iso8601("2026-07-30T09:05:00+03:00")
    next_minute = Time.iso8601("2026-07-30T09:06:00+03:00")

    assert_equal 2, state.requests_per_minute(at: first_minute)
    state.record_request!(at: first_minute)
    assert_equal 3, state.requests_per_minute(at: first_minute)
    assert_equal 0, state.requests_per_minute(at: next_minute)
  end

  def test_reservation_enforces_rate_limit_atomically
    state = provider(requests_per_minute_limit: 3, requests_last_minute: 2)
    request_time = Time.iso8601("2026-07-30T09:05:00+03:00")
    state.reserve!(500, reservation_id: "first", at: request_time)
    state.reject!(reservation_id: "first")

    before = state.snapshot
    assert_raises(RouteLens::CapacityExceeded) do
      state.reserve!(500, reservation_id: "second", at: request_time)
    end
    assert_equal before, state.snapshot
  end

  def test_supports_hash_style_access_for_policy_components
    state = provider(conversion_24h: 0.9)
    assert state.key?(:conversion_24h)
    assert_equal 0.9, state[:conversion_24h]
    assert_equal "testpay", state.fetch(:payment_system)
  end
end
