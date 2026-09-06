# frozen_string_literal: true

require_relative "../test_helper"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

class ReleaseCommandIntegrationTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def test_release_command_protects_required_paths_and_filenames
    command = File.join(ROOT, "bin/release_test_case")
    _stdout, stderr, status = Open3.capture3(
      RbConfig.ruby,
      command,
      "--decisions",
      File.join(ROOT, "wrong-name.json")
    )

    assert_equal 2, status.exitstatus
    assert_includes stderr, "cannot be overridden"
    refute File.exist?(File.join(ROOT, "wrong-name.json"))
  end

  def test_release_command_rejects_fixture_outcome_overrides
    command = File.join(ROOT, "bin/release_test_case")
    _stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, command, "--outcome-overrides", File.join(ROOT, "test/fixtures/resilience_outcomes.json")
    )

    assert_equal 2, status.exitstatus
    assert_includes stderr, "cannot be overridden"
  end

  def test_release_checker_detects_semantic_mismatch
    Dir.mktmpdir("route-lens-release-check") do |directory|
      decisions = File.join(directory, "decisions.json")
      report = File.join(directory, "report.json")
      queue = File.join(ROOT, "data/operations_queue_10.json")
      route = File.join(ROOT, "bin/route")
      check = File.join(ROOT, "scripts/release_check.rb")
      _stdout, stderr, status = Open3.capture3(
        RbConfig.ruby, route,
        "--queue", queue, "--decisions", decisions, "--report", report, "--quiet"
      )
      assert status.success?, stderr

      parsed = JSON.parse(File.read(report))
      parsed["distribution"]["quickpay"]["count"] += 1
      File.write(report, JSON.generate(parsed))
      _stdout, checker_stderr, checker_status = Open3.capture3(
        RbConfig.ruby, check, "--queue", queue, "--decisions", decisions, "--report", report
      )

      refute checker_status.success?
      assert_includes checker_stderr, "distribution"
    end
  end

  def test_release_command_protects_the_compact_flag
    command = File.join(ROOT, "bin/release_test_case")
    _stdout, stderr, status = Open3.capture3(RbConfig.ruby, command, "--compact")

    assert_equal 2, status.exitstatus
    assert_includes stderr, "cannot be overridden"
  end

  # Невыполнимая операция допустима, но ровно в одной форме: пустой провайдер и
  # код no_provider_available. Обычное решение без выбранной попытки — ошибка.
  def test_release_checker_accepts_the_unroutable_record_but_still_demands_a_selected_attempt
    Dir.mktmpdir("route-lens-unroutable") do |directory|
      decisions = File.join(directory, "decisions.json")
      report = File.join(directory, "report.json")
      providers = File.join(directory, "providers.json")
      queue = File.join(directory, "queue.json")
      snapshot = JSON.parse(File.read(File.join(ROOT, "data/providers.json")))
      snapshot["providers"] = snapshot.fetch("providers").reject { |item| item["payment_system"] == "spacepayments" }
      File.write(providers, JSON.generate(snapshot))
      File.write(queue, JSON.generate([
        { "operation_id" => "op_impossible", "created_at" => "2026-07-30T09:05:00+03:00",
          "amount" => 99_999_999, "bank" => "zzz" },
        { "operation_id" => "op_ok", "created_at" => "2026-07-30T09:05:30+03:00",
          "amount" => 15_000, "bank" => "sberbank" }
      ]))

      _stdout, stderr, status = Open3.capture3(
        RbConfig.ruby, File.join(ROOT, "bin/route"),
        "--providers", providers, "--queue", queue,
        "--decisions", decisions, "--report", report, "--quiet"
      )
      assert status.success?, stderr

      check = File.join(ROOT, "scripts/release_check.rb")
      _stdout, _stderr, checker_status = Open3.capture3(
        RbConfig.ruby, check, "--providers", providers,
        "--queue", queue, "--decisions", decisions, "--report", report
      )
      assert checker_status.success?

      parsed = JSON.parse(File.read(decisions))
      routed = parsed.find { |decision| decision["selected_provider"] }
      routed.fetch("attempts").each { |attempt| attempt["decision"] = "skipped" }
      File.write(decisions, JSON.generate(parsed))
      _stdout, mutated_stderr, mutated_status = Open3.capture3(
        RbConfig.ruby, check, "--providers", providers,
        "--queue", queue, "--decisions", decisions, "--report", report
      )

      refute mutated_status.success?
      assert_includes mutated_stderr, "no selected provider attempt"
    end
  end

  def test_release_checker_rejects_ineligible_selected_attempt
    Dir.mktmpdir("route-lens-semantic-check") do |directory|
      decisions = File.join(directory, "decisions.json")
      report = File.join(directory, "report.json")
      queue = File.join(ROOT, "data/operations_queue_10.json")
      route = File.join(ROOT, "bin/route")
      check = File.join(ROOT, "scripts/release_check.rb")
      _stdout, stderr, status = Open3.capture3(
        RbConfig.ruby, route,
        "--queue", queue, "--decisions", decisions, "--report", report, "--quiet"
      )
      assert status.success?, stderr

      parsed = JSON.parse(File.read(decisions))
      selected = parsed.first.fetch("attempts").find { |attempt| attempt["decision"] == "selected" }
      selected.fetch("state_before")["status"] = "inactive"
      File.write(decisions, JSON.generate(parsed))
      _stdout, checker_stderr, checker_status = Open3.capture3(
        RbConfig.ruby, check, "--queue", queue, "--decisions", decisions, "--report", report
      )

      refute checker_status.success?
      assert_includes checker_stderr, "violates provider_inactive"
    end
  end
end
