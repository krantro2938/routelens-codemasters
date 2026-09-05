# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper_eligibility"

class EligibilityInputLoaderTest < Minitest::Test
  def valid_provider(overrides = {})
    {
      payment_system: "provider",
      status: "active",
      traffic_percentage: 25,
      limit_amount_min: 100,
      limit_amount_max: 10_000,
      daily_amount_limit: 100_000,
      daily_approved_amount: 0,
      in_progress_count_limit: 10,
      in_progress_count: 0,
      in_progress_amount_limit: 100_000,
      in_progress_amount: 0,
      available_requisites: 1,
      conversion_24h: 0.8,
      banks: [],
      exclude_banks: false,
      provider_margin_pct: 1,
      merchant_margin_pct: 2,
      allow_negative_agreement: false
    }.merge(overrides)
  end

  def write_snapshot(directory, provider)
    path = File.join(directory, "providers.json")
    File.write(path, JSON.generate({ providers: [provider] }))
    path
  end

  def test_loads_supplied_inputs_into_provider_states
    root = File.expand_path("../..", __dir__)
    snapshot = RouteLens::InputLoader.load_provider_snapshot(File.join(root, "data/providers.json"))
    operations = RouteLens::InputLoader.load_operations(File.join(root, "data/operations_queue_10.json"))
    history = RouteLens::InputLoader.load_history(File.join(root, "data/operations_history.csv"))

    assert_equal 4, snapshot.fetch("providers").length
    assert_instance_of RouteLens::ProviderState, snapshot.fetch("providers").first
    assert_equal 10, operations.length
    assert_equal 100, history.length
    assert_kind_of Float, history.first.fetch("amount")
  end

  def test_rejects_duplicate_operation_ids
    Dir.mktmpdir do |dir|
      path = File.join(dir, "queue.json")
      File.write(path, JSON.generate([
        { operation_id: "same", amount: 1, bank: "vtb" },
        { operation_id: "same", amount: 2, bank: "vtb" }
      ]))

      error = assert_raises(RouteLens::InputError) { RouteLens::InputLoader.load_operations(path) }
      assert_match(/duplicate operation_id/, error.message)
    end
  end

  def test_wraps_missing_and_malformed_file_errors
    assert_raises(RouteLens::InputError) { RouteLens::InputLoader.load_operations("/does/not/exist.json") }

    Dir.mktmpdir do |dir|
      path = File.join(dir, "broken.json")
      File.write(path, "{")
      assert_raises(RouteLens::InputError) { RouteLens::InputLoader.load_operations(path) }
    end
  end

  def test_rejects_inverted_amount_range
    assert_invalid_provider(limit_amount_min: 2_000, limit_amount_max: 1_000, matching: /limit_amount_min cannot exceed/)
  end

  def test_rejects_conversion_outside_probability_range
    assert_invalid_provider(conversion_24h: 1.01, matching: /conversion_24h must be between/)
    assert_invalid_provider(conversion_24h: -0.01, matching: /conversion_24h cannot be negative/)
  end

  def test_rejects_percentages_outside_zero_to_one_hundred
    assert_invalid_provider(traffic_percentage: 101, matching: /traffic_percentage must be between/)
    assert_invalid_provider(volume_share_pct: 100.1, matching: /volume_share_pct must be between/)
  end

  def test_rejects_negative_limits_and_counters
    %i[
      daily_amount_limit daily_approved_amount in_progress_count_limit in_progress_count
      in_progress_amount_limit in_progress_amount available_requisites requests_per_minute_limit
    ].each do |field|
      assert_invalid_provider(field => -1, matching: /#{field} cannot be negative/)
    end
  end

  def test_rejects_non_boolean_flags
    assert_invalid_provider(exclude_banks: "false", matching: /exclude_banks must be boolean/)
    assert_invalid_provider(allow_negative_agreement: 1, matching: /allow_negative_agreement must be boolean/)
  end

  def test_accepts_any_nonempty_non_active_status_for_forward_compatibility
    %w[inactive disabled maintenance paused suspended unavailable].each do |status|
      Dir.mktmpdir do |dir|
        states = RouteLens::InputLoader.load_providers(write_snapshot(dir, valid_provider(status: status)))
        assert_equal status, states.first["status"]
      end
    end
  end

  def test_rejects_non_finite_provider_and_operation_numbers
    # JSON не принимает литералы Infinity/NaN, поэтому используем слишком большую
    # экспоненту: Ruby читает её как Infinity, а схема всё равно должна отклонить.
    Dir.mktmpdir do |dir|
      provider_path = File.join(dir, "providers.json")
      File.write(provider_path, '{"providers":[{"payment_system":"p","status":"active","conversion_24h":1e999,"banks":[]}]}')
      assert_raises(RouteLens::InputError) { RouteLens::InputLoader.load_providers(provider_path) }

      operation_path = File.join(dir, "operations.json")
      File.write(operation_path, '[{"operation_id":"op","amount":1e999,"bank":"vtb"}]')
      assert_raises(RouteLens::InputError) { RouteLens::InputLoader.load_operations(operation_path) }
    end
  end

  private

  def assert_invalid_provider(overrides)
    matching = overrides.delete(:matching)
    Dir.mktmpdir do |dir|
      path = write_snapshot(dir, valid_provider(overrides))
      error = assert_raises(RouteLens::InputError) { RouteLens::InputLoader.load_providers(path) }
      assert_match matching, error.message
    end
  end
end
