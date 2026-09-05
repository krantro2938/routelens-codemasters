# frozen_string_literal: true

require_relative "../test_helper"
require "json"
require "tmpdir"
require "route_lens/cli"

class CLIIntegrationTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def test_cli_generates_deterministic_decisions_and_report
    Dir.mktmpdir("route-lens-cli") do |directory|
      decisions = File.join(directory, "decisions.json")
      report = File.join(directory, "report.json")
      arguments = common_arguments(decisions, report)

      first_stdout, first_stderr = capture_io { assert_equal 0, RouteLens::CLI.run(arguments) }
      first_decisions = File.read(decisions)
      first_report = File.read(report)
      second_stdout, second_stderr = capture_io { assert_equal 0, RouteLens::CLI.run(arguments) }

      assert_empty first_stdout
      assert_empty first_stderr
      assert_empty second_stdout
      assert_empty second_stderr
      assert_equal first_decisions, File.read(decisions)
      assert_equal first_report, File.read(report)

      parsed_decisions = JSON.parse(first_decisions)
      parsed_report = JSON.parse(first_report)
      assert_equal 10, parsed_decisions.length
      assert_equal 10, parsed_report["total_operations"]
      assert_equal 10, parsed_report.dig("routing_attempts", "total_attempts")
      refute_empty parsed_report["recommendations"]
    end
  end

  def test_cli_rejects_same_path_for_both_outputs
    Dir.mktmpdir("route-lens-cli") do |directory|
      output = File.join(directory, "same.json")
      _stdout, stderr = capture_io do
        assert_equal 1, RouteLens::CLI.run(common_arguments(output, output))
      end

      assert_includes stderr, "must use different paths"
      refute File.exist?(output)
    end
  end

  private

  def common_arguments(decisions, report)
    [
      "--providers", File.join(ROOT, "data/providers.json"),
      "--history", File.join(ROOT, "data/operations_history.csv"),
      "--queue", File.join(ROOT, "data/operations_queue_10.json"),
      "--policy", File.join(ROOT, "config/routing.yml"),
      "--decisions", decisions,
      "--report", report,
      "--seed", "2026",
      "--quiet"
    ]
  end
end
