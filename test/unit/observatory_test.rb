# frozen_string_literal: true

require_relative "../test_helper"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require "route_lens/observatory"

class ObservatoryTest < Minitest::Test
  def decisions
    [
      {
        "operation_id" => "op_<unsafe>",
        "selected_provider" => "vipay",
        "simulated_result" => "approved",
        "latency_sec" => 31,
        "attempts" => [
          {
            "provider" => "vipay",
            "decision" => "selected",
            "reason" => "highest_policy_score",
            "details" => "safe </script><script>alert(1)</script>",
            "score_breakdown" => {
              "conversion" => { "raw" => 0.9, "weight" => 2, "contribution" => 1.8 }
            }
          }
        ]
      }
    ]
  end

  def report
    {
      "period" => "2026-07-30",
      "total_operations" => 1,
      "distribution" => {
        "vipay" => { "share_pct" => 60, "target_pct" => 40, "delta_pct" => 20 }
      },
      "outcomes" => {
        "approval_rate_pct" => 100,
        "rejected" => { "count" => 0 },
        "expired" => { "count" => 0 }
      },
      "routing_resilience" => { "retry_count" => 2, "fallback_count" => 1 },
      "attempt_outcomes" => {
        "rejected" => 1, "expired" => 1, "recovered_operations" => 1, "recovery_rate_pct" => 50
      },
      "capacity_utilization" => {
        "vipay" => { "utilization_pct" => 65.5, "headroom" => 1_725_000 }
      },
      "recommendations" => ["Reduce traffic & inspect limits"]
    }
  end

  def test_render_contains_required_offline_dashboard_sections
    html = RouteLens::Observatory.new(decisions: decisions, report: report).render

    assert_includes html, "Routing Observatory"
    assert_includes html, "Count share: actual vs target"
    assert_includes html, "Daily capacity"
    assert_includes html, "Recommended actions"
    assert_includes html, "Inspect an operation"
    assert_includes html, "Score breakdown"
    assert_includes html, "Retries"
    assert_includes html, "Fallbacks"
    assert_includes html, "Provider failures"
    assert_includes html, "Codemasters · RouteLens"
    refute_match(%r{https?://}, html)
  end

  def test_distribution_labels_do_not_break_inside_provider_names
    html = RouteLens::Observatory.new(decisions: decisions, report: report).render

    assert_includes html, ".provider { font-weight: 750; white-space: nowrap; }"
    assert_includes html, ".distribution-row { grid-template-columns: minmax(0, 1fr); gap: 7px; }"
    assert_includes html, ".provider, .bar-pair, .bar-values { grid-column: 1; }"
  end

  def test_render_escapes_static_html_and_script_terminators
    html = RouteLens::Observatory.new(decisions: decisions, report: report).render

    assert_includes html, "op_&lt;unsafe&gt;"
    assert_includes html, "Reduce traffic &amp; inspect limits"
    refute_includes html, "</script><script>alert(1)</script>"
    assert_includes html, "\\u003c/script\\u003e\\u003cscript\\u003ealert(1)"
  end

  def test_embedded_data_remains_valid_json
    html = RouteLens::Observatory.new(decisions: decisions, report: report).render
    payload = html.match(%r{<script id="route-lens-data" type="application/json">(.*?)</script>}m)[1]
    parsed = JSON.parse(payload)

    assert_equal "op_<unsafe>", parsed.dig("decisions", 0, "operation_id")
    assert_equal report, parsed["report"]
  end

  def test_rejects_wrong_top_level_shapes
    assert_raises(RouteLens::Observatory::InputError) do
      RouteLens::Observatory.new(decisions: {}, report: report)
    end
    assert_raises(RouteLens::Observatory::InputError) do
      RouteLens::Observatory.new(decisions: decisions, report: [])
    end
  end

  def test_cli_generates_requested_output
    Dir.mktmpdir do |directory|
      decisions_path = File.join(directory, "decisions.json")
      report_path = File.join(directory, "report.json")
      output_path = File.join(directory, "observatory.html")
      File.write(decisions_path, JSON.generate(decisions))
      File.write(report_path, JSON.generate(report))
      executable = File.expand_path("../../bin/observatory", __dir__)

      stdout, stderr, status = Open3.capture3(
        RbConfig.ruby, executable,
        "--decisions", decisions_path,
        "--report", report_path,
        "--output", output_path
      )

      assert status.success?, stderr
      assert_equal "Wrote #{output_path}\n", stdout
      assert File.file?(output_path)
      assert_includes File.read(output_path), "op_&lt;unsafe&gt;"
    end
  end
end
