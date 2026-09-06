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

    assert_includes html, "Центр<br>маршрутизации"
    assert_includes html, "Доля операций: факт и цель"
    assert_includes html, "Дневная ёмкость"
    assert_includes html, "Рекомендуемые действия"
    assert_includes html, "Разбор операции"
    assert_includes html, "Разложение итоговой оценки"
    assert_includes html, "Повторные попытки"
    assert_includes html, "Fallback"
    assert_includes html, "Сбои провайдеров"
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

# Подписи больше не дублируются в JavaScript: страница читает их из того же
# экранированного JSON, поэтому Ruby остаётся единственным источником правды.
def test_labels_travel_with_embedded_data_instead_of_hardcoded_javascript
  html = RouteLens::Observatory.new(decisions: decisions, report: report).render
  payload = html.match(%r{<script id="route-lens-data" type="application/json">(.*?)</script>}m)[1]
  labels = JSON.parse(payload).fetch("labels")

  assert_equal "провайдер неактивен", labels.dig("reasons", "provider_inactive")
  assert_equal "наивысшая оценка политики", labels.dig("reasons", "highest_policy_score")
  assert_equal "Конверсия", labels.dig("factors", "conversion")
  assert_equal "одобрено", labels.dig("outcomes", "approved")
  refute_includes html, "provider_inactive: "
  refute_includes html, "count_target_gain: "
end

# Новое правило допуска в Ruby не должно молча превращаться в snake_case
# на странице: словарь причин обязан покрывать все коды из исходников.
def test_reason_labels_cover_every_reason_code_emitted_by_ruby
  codes = ruby_reason_codes

  assert_includes codes, "provider_inactive"
  assert_includes codes, "external_pool_exhausted"
  codes.each do |code|
    assert RouteLens::Observatory::REASON_LABELS.key?(code),
           "Нет русской подписи для кода причины #{code}"
  end
end

def test_factor_labels_cover_every_scoring_factor_of_the_router
  RouteLens::Router::FACTOR_LABELS.each_key do |factor|
    assert RouteLens::Observatory::FACTOR_LABELS.key?(factor),
           "Нет подписи для фактора #{factor}"
  end
end

def test_template_placeholders_are_fully_substituted
  html = RouteLens::Observatory.new(decisions: decisions, report: report).render

  refute_match(/\{\{[A-Z_]+\}\}/, html)
end

# Вынос стилей и скрипта в отдельные файлы не должен ослабить защиту:
# проверяем CSP, отсутствие внешних ссылок и запрет innerHTML.
def test_inlined_assets_keep_the_offline_security_contract
  html = RouteLens::Observatory.new(decisions: decisions, report: report).render

  assert_includes html,
                  "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; " \
                  "style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data:\">"
  assert_includes html, "<style>"
  assert_includes html, "<script>"
  refute_match(/<link\b/, html)
  refute_match(/\bsrc=(?!")/, html)
  refute_match(%r{\bsrc="(?!data:)}, html)
  refute_includes html, "innerHTML"
  assert_includes html, "node.textContent = String(value);"
end

# Плейсхолдер подставляется одним проходом, поэтому текст из данных не может
# притвориться меткой шаблона и получить подстановку второго уровня.
def test_placeholder_syntax_inside_data_is_not_substituted
  hostile = decisions
  hostile[0]["operation_id"] = "{{EMBEDDED_DATA}}"
  html = RouteLens::Observatory.new(decisions: hostile, report: report).render

  assert_includes html, "<option value=\"{{EMBEDDED_DATA}}\">{{EMBEDDED_DATA}}</option>"
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

  private

  # Коды причин собираем прямо из исходников правил и роутера: тест падает,
  # если появился код без перевода в Observatory.
  def ruby_reason_codes
    root = File.expand_path("../..", __dir__)
    rules = File.read(File.join(root, "lib/route_lens/eligibility/rules.rb"))
    router = File.read(File.join(root, "lib/route_lens/router.rb"))
    codes = rules.scan(/fail\(\s*"([a-z_]+)"/).flatten
    codes += router.scan(/"reason" => (.+)$/).flatten.flat_map do |expression|
      expression.scan(/(?<!\[)"([a-z_]+)"/).flatten
    end
    codes.uniq
  end
end
