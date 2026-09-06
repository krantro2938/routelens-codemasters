# frozen_string_literal: true

require_relative "../test_helper"
require "json"
require "open3"
require "rbconfig"
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

  # Компактный файл — та же маршрутизация, но только поля спецификации.
  def test_compact_flag_emits_the_spec_minimal_shape
    Dir.mktmpdir("route-lens-cli") do |directory|
      rich = File.join(directory, "rich.json")
      compact = File.join(directory, "compact.json")
      report = File.join(directory, "report.json")

      capture_io { assert_equal 0, RouteLens::CLI.run(common_arguments(rich, report)) }
      capture_io { assert_equal 0, RouteLens::CLI.run(common_arguments(compact, report) + ["--compact"]) }

      rich_decisions = JSON.parse(File.read(rich))
      compact_decisions = JSON.parse(File.read(compact))

      assert_equal rich_decisions.map { |decision| decision["selected_provider"] },
                   compact_decisions.map { |decision| decision["selected_provider"] }
      assert_equal %w[operation_id selected_provider attempts simulated_result latency_sec],
                   compact_decisions.first.keys
      assert_equal %w[provider decision reason details], compact_decisions.first.fetch("attempts").first.keys
      assert_operator File.size(compact), :<, File.size(rich)
      # По умолчанию доказательства резерва остаются на месте.
      assert rich_decisions.first.fetch("attempts").any? { |attempt| attempt.key?("state_reserved") }
      refute rich_decisions.first.key?("state_changes")
    end
  end

  # Одна невыполнимая выплата не должна уносить с собой остальные решения.
  def test_unroutable_operation_keeps_the_batch_and_exit_status
    Dir.mktmpdir("route-lens-cli") do |directory|
      decisions = File.join(directory, "decisions.json")
      report = File.join(directory, "report.json")
      providers = write_providers_without_fallback(directory)
      queue = write_queue(directory, "mixed.json", [impossible_operation, routable_operation])

      arguments = replace_paths(common_arguments(decisions, report), providers, queue) - ["--quiet"]
      stdout, = capture_io { assert_equal 0, RouteLens::CLI.run(arguments) }

      parsed = JSON.parse(File.read(decisions))
      assert_equal 2, parsed.length
      assert_nil parsed.first["selected_provider"]
      assert_equal "no_provider_available", parsed.first.fetch("attempts").last.fetch("reason")
      refute_nil parsed.last["selected_provider"]
      assert_includes stdout, "RouteLens routed 1 of 2 operation(s)."
      assert_includes stdout, "Unroutable: 1 operation(s)"
    end
  end

  def test_batch_without_any_routable_operation_exits_non_zero_but_still_writes_files
    Dir.mktmpdir("route-lens-cli") do |directory|
      decisions = File.join(directory, "decisions.json")
      report = File.join(directory, "report.json")
      providers = write_providers_without_fallback(directory)
      queue = write_queue(directory, "impossible.json", [impossible_operation])

      capture_io do
        assert_equal RouteLens::CLI::NOTHING_ROUTED_STATUS,
                     RouteLens::CLI.run(replace_paths(common_arguments(decisions, report), providers, queue))
      end

      assert File.file?(decisions)
      assert File.file?(report)
      assert_equal 1, JSON.parse(File.read(decisions)).length
    end
  end

  # Параметры правил приходят из конфигурации: лимит запросов в минуту нигде не
  # зашит в коде и виден в снимке провайдера.
  def test_provider_overrides_from_the_policy_file_reach_the_run
    Dir.mktmpdir("route-lens-cli") do |directory|
      decisions = File.join(directory, "decisions.json")
      report = File.join(directory, "report.json")
      operations = Array.new(6) do |index|
        {
          "operation_id" => format("rl_%03d", index + 1),
          "created_at" => "2026-07-30T09:05:00+03:00",
          "amount" => 5_000,
          "bank" => "alfa"
        }
      end
      queue = write_queue(directory, "dense.json", operations)
      policy = File.join(directory, "policy.yml")
      File.write(policy, File.read(File.join(ROOT, "config/routing.yml")).sub(
        "  payflow:\n    requests_per_minute_limit: 7", "  payflow:\n    requests_per_minute_limit: 2"
      ))

      arguments = common_arguments(decisions, report)
      arguments[arguments.index("--policy") + 1] = policy
      arguments[arguments.index("--queue") + 1] = queue
      capture_io { assert_equal 0, RouteLens::CLI.run(arguments) }

      attempts = JSON.parse(File.read(decisions)).flat_map { |decision| decision.fetch("attempts") }
      rate_limited = attempts.select { |attempt| attempt["reason"] == "rate_limit_exceeded" }
      refute_empty rate_limited
      assert_equal ["payflow"], rate_limited.map { |attempt| attempt["provider"] }.uniq
    end
  end

  # Внутренняя ошибка не должна показывать судье сырой стек Ruby.
  def test_unexpected_internal_error_is_reported_without_a_stack_trace
    Dir.mktmpdir("route-lens-cli") do |directory|
      decisions = File.join(directory, "decisions.json")
      report = File.join(directory, "report.json")

      # Ошибку внедряем в отдельном процессе: подмена метода не должна протечь
      # в остальные тесты.
      script = <<~RUBY
        $LOAD_PATH.unshift(#{File.join(ROOT, 'lib').inspect})
        require "route_lens/cli"
        module RouteLens
          class Router
            def route(_operations)
              raise NoMethodError, "undefined method 'fetch' for nil"
            end
          end
        end
        exit RouteLens::CLI.run(ARGV)
      RUBY
      _stdout, stderr, status = Open3.capture3(
        RbConfig.ruby, "-e", script, "--", *common_arguments(decisions, report)
      )

      assert_equal 1, status.exitstatus
      assert_includes stderr, "RouteLens internal error (NoMethodError)"
      refute_match(/cli\.rb:\d+:in/, stderr)
      refute File.exist?(decisions)
    end
  end

  # Справка обязана завершать запуск: иначе bin/route --help молча
  # перезаписывал бы routing_decisions.json обычным прогоном.
  def test_help_prints_usage_and_writes_nothing
    Dir.mktmpdir("route-lens-cli") do |directory|
      decisions = File.join(directory, "decisions.json")
      report = File.join(directory, "report.json")
      stdout, _stderr, status = Open3.capture3(
        RbConfig.ruby, File.join(ROOT, "bin/route"), "--help",
        "--decisions", decisions, "--report", report
      )

      assert_equal 0, status.exitstatus
      assert_includes stdout, "Usage: ruby bin/route"
      refute_includes stdout, "RouteLens routed"
      refute File.exist?(decisions)
      refute File.exist?(report)
    end
  end

  private

  def impossible_operation
    { "operation_id" => "op_impossible", "created_at" => "2026-07-30T09:05:00+03:00", "amount" => 99_999_999, "bank" => "zzz" }
  end

  def routable_operation
    { "operation_id" => "op_ok", "created_at" => "2026-07-30T09:05:00+03:00", "amount" => 15_000, "bank" => "sberbank" }
  end

  def write_queue(directory, name, operations)
    path = File.join(directory, name)
    File.write(path, JSON.generate(operations))
    path
  end

  def write_providers_without_fallback(directory)
    snapshot = JSON.parse(File.read(File.join(ROOT, "data/providers.json")))
    snapshot["providers"] = snapshot.fetch("providers").reject { |provider| provider["payment_system"] == "spacepayments" }
    path = File.join(directory, "providers.json")
    File.write(path, JSON.generate(snapshot))
    path
  end

  def replace_paths(arguments, providers, queue)
    arguments = arguments.dup
    arguments[arguments.index("--providers") + 1] = providers
    arguments[arguments.index("--queue") + 1] = queue
    arguments
  end

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
