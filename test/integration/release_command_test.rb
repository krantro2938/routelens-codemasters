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
