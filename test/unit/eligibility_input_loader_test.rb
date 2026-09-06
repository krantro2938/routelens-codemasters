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

  def test_history_rejects_invalid_timestamp_status_and_empty_bank
    Dir.mktmpdir do |dir|
      invalid_timestamp = write_history(dir, "bad-time.csv", created_at: "yesterday")
      assert_match(/created_at must be an ISO 8601 timestamp/, assert_raises(RouteLens::InputError) do
        RouteLens::InputLoader.load_history(invalid_timestamp)
      end.message)

      invalid_status = write_history(dir, "bad-status.csv", status: "success")
      assert_match(/status must be approved, rejected, or expired/, assert_raises(RouteLens::InputError) do
        RouteLens::InputLoader.load_history(invalid_status)
      end.message)

      empty_bank = write_history(dir, "empty-bank.csv", bank: "")
      assert_match(/bank must be a non-empty string/, assert_raises(RouteLens::InputError) do
        RouteLens::InputLoader.load_history(empty_bank)
      end.message)
    end
  end

  def test_history_rejects_duplicate_operation_ids_and_zero_amount
    Dir.mktmpdir do |dir|
      duplicate = write_history(dir, "duplicate.csv", rows: 2)
      assert_match(/duplicate history operation_id/, assert_raises(RouteLens::InputError) do
        RouteLens::InputLoader.load_history(duplicate)
      end.message)

      zero_amount = write_history(dir, "zero.csv", amount: 0)
      assert_match(/amount must be greater than zero/, assert_raises(RouteLens::InputError) do
        RouteLens::InputLoader.load_history(zero_amount)
      end.message)
    end
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

  # bank не входит в обязательный контракт операции: одна выплата без банка не
  # должна обнулить весь файл очереди.
  def test_bank_is_optional_and_missing_bank_does_not_reject_the_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, "queue.json")
      File.write(path, JSON.generate([
        { operation_id: "with_bank", amount: 1_000, bank: "vtb" },
        { operation_id: "null_bank", amount: 1_000, bank: nil },
        { operation_id: "no_bank_key", amount: 1_000 }
      ]))

      operations = RouteLens::InputLoader.load_operations(path)

      assert_equal 3, operations.length
      assert_nil operations[1]["bank"]
      refute operations[2].key?("bank")
    end
  end

  # Пустой банк деградирует консервативно: провайдер со списком banks
  # отсеивается, провайдер с пустым списком остаётся допустимым.
  def test_missing_bank_skips_allowlisted_providers_and_keeps_open_providers
    rule = RouteLens::Eligibility::BankRule.new
    allowlisted = { "payment_system" => "payflow", "banks" => %w[sberbank alfa] }
    open_provider = { "payment_system" => "quickpay", "banks" => [] }
    operation = { "operation_id" => "op", "amount" => 1_000 }

    refute rule.evaluate(allowlisted, operation).eligible?
    assert_equal "bank_not_in_list", rule.evaluate(allowlisted, operation).reason
    assert rule.evaluate(open_provider, operation).eligible?
  end

  def test_operation_id_and_amount_stay_mandatory
    Dir.mktmpdir do |dir|
      path = File.join(dir, "queue.json")
      File.write(path, JSON.generate([{ amount: 1_000, bank: "vtb" }]))
      assert_match(/operation_id/, assert_raises(RouteLens::InputError) do
        RouteLens::InputLoader.load_operations(path)
      end.message)

      File.write(path, JSON.generate([{ operation_id: "op", bank: "vtb" }]))
      assert_match(/amount/, assert_raises(RouteLens::InputError) do
        RouteLens::InputLoader.load_operations(path)
      end.message)
    end
  end

  # Параметры правил настраиваются конфигурацией, а вход организаторов остаётся
  # неизменным: переопределение проходит ту же валидацию, что и родное поле.
  def test_provider_overrides_are_applied_and_validated
    Dir.mktmpdir do |dir|
      path = write_snapshot(dir, valid_provider)
      providers = RouteLens::InputLoader.load_providers(
        path, overrides: { "provider" => { "requests_per_minute_limit" => 7 } }
      )

      assert_equal 7, providers.first["requests_per_minute_limit"]

      error = assert_raises(RouteLens::InputError) do
        RouteLens::InputLoader.load_providers(path, overrides: { "provider" => { "requests_per_minute_limit" => -1 } })
      end
      assert_match(/requests_per_minute_limit cannot be negative/, error.message)
    end
  end

  def test_provider_overrides_reject_unknown_and_malformed_entries
    Dir.mktmpdir do |dir|
      path = write_snapshot(dir, valid_provider)

      error = assert_raises(RouteLens::InputError) do
        RouteLens::InputLoader.load_providers(path, overrides: { "ghostpay" => { "priority" => 1 } })
      end
      assert_match(/unknown payment_system: ghostpay/, error.message)

      assert_raises(RouteLens::InputError) do
        RouteLens::InputLoader.load_providers(path, overrides: { "provider" => "not-an-object" })
      end
      assert_raises(RouteLens::InputError) do
        RouteLens::InputLoader.load_providers(path, overrides: "not-an-object")
      end
    end
  end

  private

  def write_history(directory, name, rows: 1, **overrides)
    path = File.join(directory, name)
    item = {
      operation_id: "history_op", created_at: "2026-07-29T09:00:00+03:00",
      amount: 1_000, bank: "vtb", payment_system: "provider",
      status: "approved", latency_sec: 10
    }.merge(overrides)
    headers = %i[operation_id created_at amount bank payment_system status latency_sec]
    body = ([headers.join(",")] + Array.new(rows) { headers.map { |header| item.fetch(header) }.join(",") }).join("\n")
    File.write(path, "#{body}\n")
    path
  end

  def assert_invalid_provider(overrides)
    matching = overrides.delete(:matching)
    Dir.mktmpdir do |dir|
      path = write_snapshot(dir, valid_provider(overrides))
      error = assert_raises(RouteLens::InputError) { RouteLens::InputLoader.load_providers(path) }
      assert_match matching, error.message
    end
  end
end
