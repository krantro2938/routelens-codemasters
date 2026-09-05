# frozen_string_literal: true

require "json"

module RouteLens
  # Генерирует переносимое представление сохранённых артефактов без зависимостей.
  # Динамический текст выводится через DOM textContent, а встроенный JSON
  # экранирует HTML-символы, поэтому входные данные не становятся разметкой.
  class Observatory
    class InputError < StandardError; end

    attr_reader :decisions, :report

    def self.generate(decisions_path:, report_path:, output_path:, comparison_path: nil)
      decisions = parse_json(decisions_path, "decisions")
      report = parse_json(report_path, "report")
      report["policy_comparison"] = parse_json(comparison_path, "policy comparison") if comparison_path
      html = new(decisions: decisions, report: report).render
      File.write(output_path, html)
      output_path
    rescue Errno::ENOENT => e
      raise InputError, "Input file not found: #{e.message}"
    rescue Errno::EACCES => e
      raise InputError, "Cannot access artifact: #{e.message}"
    end

    def self.parse_json(path, label)
      JSON.parse(File.read(path))
    rescue JSON::ParserError => e
      raise InputError, "Invalid #{label} JSON in #{path}: #{e.message}"
    end
    private_class_method :parse_json

    def initialize(decisions:, report:)
      raise InputError, "Decisions must be a JSON array" unless decisions.is_a?(Array)
      raise InputError, "Report must be a JSON object" unless report.is_a?(Hash)

      @decisions = decisions
      @report = report
    end

    def render
      html = <<~HTML
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta name="color-scheme" content="light dark">
          <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data:">
          <title>RouteLens Routing Observatory</title>
          <style>
            :root {
              color-scheme: light dark;
              --bg: #f4f5f0;
              --surface: #ffffff;
              --surface-raised: #f9faf6;
              --ink: #17201d;
              --muted: #63706b;
              --line: #dce2dc;
              --accent: #087f5b;
              --accent-soft: #c9f3e4;
              --target: #ff9f1c;
              --danger: #c92a2a;
              --shadow: 0 18px 48px rgba(23, 32, 29, .09);
              --radius: 20px;
              font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
            }
            @media (prefers-color-scheme: dark) {
              :root {
                --bg: #101613;
                --surface: #18201c;
                --surface-raised: #202a25;
                --ink: #edf5f0;
                --muted: #a8b8b0;
                --line: #34423b;
                --accent: #69dbb3;
                --accent-soft: #173f31;
                --target: #ffc65c;
                --danger: #ff8787;
                --shadow: 0 18px 48px rgba(0, 0, 0, .28);
              }
            }
            * { box-sizing: border-box; }
            body { margin: 0; background: var(--bg); color: var(--ink); }
            main { width: min(1180px, calc(100% - 32px)); margin: 0 auto; padding: 32px 0 64px; }
            header { padding: 28px 0 24px; display: flex; justify-content: space-between; gap: 24px; align-items: end; }
            .eyebrow { color: var(--accent); font-size: .76rem; font-weight: 800; letter-spacing: .14em; text-transform: uppercase; }
            h1 { margin: 8px 0 5px; font-size: clamp(2rem, 6vw, 4.4rem); line-height: .95; letter-spacing: -.06em; }
            h2 { margin: 0 0 18px; font-size: 1.25rem; letter-spacing: -.02em; }
            h3 { margin: 0; font-size: 1rem; }
            p { color: var(--muted); }
            .meta { text-align: right; color: var(--muted); white-space: nowrap; }
            .grid { display: grid; gap: 16px; }
            .kpis { grid-template-columns: repeat(5, 1fr); margin-bottom: 16px; }
            .two-col { grid-template-columns: minmax(0, 1.25fr) minmax(280px, .75fr); margin-bottom: 16px; }
            .card { background: var(--surface); border: 1px solid var(--line); border-radius: var(--radius); padding: 22px; box-shadow: var(--shadow); }
            .kpi-label { color: var(--muted); font-size: .78rem; font-weight: 750; letter-spacing: .07em; text-transform: uppercase; }
            .kpi-value { display: block; margin-top: 7px; font-size: 2rem; font-weight: 780; letter-spacing: -.04em; }
            .kpi-note { color: var(--muted); font-size: .8rem; }
            .distribution { display: grid; gap: 18px; }
            .distribution-row { display: grid; grid-template-columns: minmax(124px, .3fr) 1fr minmax(112px, .3fr); gap: 14px; align-items: center; }
            .provider { font-weight: 750; white-space: nowrap; }
            .bar-pair { display: grid; gap: 5px; }
            .track { height: 9px; background: var(--surface-raised); border-radius: 99px; overflow: hidden; border: 1px solid var(--line); }
            .fill { display: block; width: min(var(--value), 100%); height: 100%; border-radius: inherit; background: var(--accent); }
            .fill.target { background: var(--target); opacity: .72; }
            .bar-values { text-align: right; font-variant-numeric: tabular-nums; font-size: .8rem; color: var(--muted); }
            .legend { display: flex; gap: 16px; margin-top: 18px; color: var(--muted); font-size: .75rem; }
            .dot { width: 8px; height: 8px; display: inline-block; border-radius: 50%; margin-right: 5px; background: var(--accent); }
            .dot.target { background: var(--target); }
            .capacity-list { display: grid; gap: 16px; }
            .capacity-head { display: flex; justify-content: space-between; gap: 10px; margin-bottom: 7px; }
            .capacity-head span { color: var(--muted); font-variant-numeric: tabular-nums; }
            .capacity-note { margin-top: 5px; color: var(--muted); font-size: .76rem; }
            .recommendations { margin: 0; padding: 0; list-style: none; display: grid; gap: 10px; }
            .recommendations li { border-left: 3px solid var(--target); padding: 4px 0 4px 14px; line-height: 1.5; }
            .operation-card { margin-top: 16px; }
            .operation-toolbar { display: flex; align-items: end; justify-content: space-between; gap: 16px; margin-bottom: 20px; }
            label { display: block; margin-bottom: 7px; color: var(--muted); font-size: .8rem; font-weight: 750; }
            select { min-width: min(320px, 100%); padding: 11px 38px 11px 12px; border: 1px solid var(--line); border-radius: 10px; background: var(--surface-raised); color: var(--ink); font: inherit; }
            select:focus-visible, summary:focus-visible { outline: 3px solid var(--accent); outline-offset: 3px; }
            .operation-summary { display: grid; grid-template-columns: repeat(4, 1fr); gap: 10px; margin-bottom: 18px; }
            .decision-copy { margin: 0 0 18px; padding: 14px 16px; border-left: 3px solid var(--accent); background: var(--surface-raised); border-radius: 0 10px 10px 0; color: var(--ink); line-height: 1.5; }
            .summary-item { background: var(--surface-raised); border-radius: 12px; padding: 13px; }
            .summary-item small { display: block; color: var(--muted); margin-bottom: 4px; }
            .summary-item strong { overflow-wrap: anywhere; }
            .attempts { display: grid; gap: 12px; }
            .attempt { border: 1px solid var(--line); border-radius: 14px; padding: 16px; }
            .attempt-head { display: flex; flex-wrap: wrap; align-items: center; gap: 8px; }
            .attempt-index { color: var(--muted); font-size: .75rem; }
            .badge { display: inline-flex; border-radius: 99px; padding: 4px 9px; font-size: .72rem; font-weight: 800; background: var(--accent-soft); color: var(--accent); }
            .badge.skipped { background: var(--surface-raised); color: var(--muted); border: 1px solid var(--line); }
            .badge.failed { background: color-mix(in srgb, var(--danger) 14%, transparent); color: var(--danger); }
            .attempt p { margin: 9px 0 0; font-size: .88rem; }
            details { margin-top: 13px; }
            summary { cursor: pointer; color: var(--accent); font-size: .84rem; font-weight: 700; }
            .score-wrap { overflow-x: auto; }
            table { width: 100%; margin-top: 9px; border-collapse: collapse; font-size: .8rem; }
            th, td { border-bottom: 1px solid var(--line); padding: 8px 6px; text-align: right; font-variant-numeric: tabular-nums; }
            th:first-child, td:first-child { text-align: left; }
            .empty { border: 1px dashed var(--line); border-radius: 12px; padding: 18px; color: var(--muted); }
            footer { padding-top: 20px; text-align: center; color: var(--muted); font-size: .76rem; }
            @media (max-width: 820px) {
              header { align-items: start; flex-direction: column; }
              .meta { text-align: left; }
              .kpis { grid-template-columns: repeat(2, 1fr); }
              .two-col { grid-template-columns: 1fr; }
            }
            @media (max-width: 540px) {
              main { width: min(100% - 20px, 1180px); padding-top: 12px; }
              .card { padding: 17px; border-radius: 15px; }
              .kpis, .operation-summary { grid-template-columns: 1fr 1fr; }
              .distribution-row { grid-template-columns: minmax(0, 1fr); gap: 7px; }
              .provider, .bar-pair, .bar-values { grid-column: 1; }
              .bar-values { text-align: left; }
              .operation-toolbar { align-items: stretch; flex-direction: column; }
              select { width: 100%; }
            }
            @media (prefers-reduced-motion: reduce) { * { scroll-behavior: auto !important; } }
          </style>
        </head>
        <body>
          <main>
            <header>
              <div>
                <div class="eyebrow">Decision intelligence / offline</div>
                <h1>Routing<br>Observatory</h1>
                <p>One auditable view of allocation, resilience, and every provider decision.</p>
              </div>
              <div class="meta"><strong>Codemasters · RouteLens</strong><br>#{h(period_label)}</div>
            </header>

            <section class="grid kpis" aria-label="Routing overview">
              #{kpi("Operations", number(report["total_operations"] || decisions.length), "processed in this run")}
              #{kpi("Final approval", percentage(report.dig("outcomes", "approval_rate_pct")), outcome_note)}
              #{kpi("Provider failures", number(attempt_failure_count), recovery_note)}
              #{kpi("Retries", number(retry_count), "across all operations")}
              #{kpi("Fallbacks", number(fallback_count), "to the self-provider")}
            </section>

            <div class="grid two-col">
              <section class="card" aria-labelledby="distribution-title">
                <h2 id="distribution-title">Count share: actual vs target</h2>
                <div class="distribution">#{distribution_rows}</div>
                <div class="legend" aria-hidden="true"><span><i class="dot"></i>Actual</span><span><i class="dot target"></i>Target</span></div>
              </section>
              <section class="card" aria-labelledby="capacity-title">
                <h2 id="capacity-title">Daily capacity</h2>
                <div class="capacity-list">#{capacity_rows}</div>
              </section>
            </div>

            <section class="card" aria-labelledby="recommendations-title">
              <h2 id="recommendations-title">Recommended actions</h2>
              #{recommendation_rows}
            </section>

            #{policy_comparison_section}

            <section class="card operation-card" aria-labelledby="operation-title">
              <div class="operation-toolbar">
                <div>
                  <div class="eyebrow">Decision receipt</div>
                  <h2 id="operation-title">Inspect an operation</h2>
                </div>
                <div>
                  <label for="operation-select">Operation</label>
                  <select id="operation-select">#{operation_options}</select>
                </div>
              </div>
              <div id="operation-view" aria-live="polite"></div>
              <noscript><p class="empty">Enable JavaScript to inspect operation attempts. Aggregate metrics remain available above.</p></noscript>
            </section>
            <footer>Generated locally from routing_decisions.json and routing_report.json · no network required</footer>
          </main>

          <script id="route-lens-data" type="application/json">#{embedded_data}</script>
          <script>
            (() => {
              "use strict";
              const data = JSON.parse(document.getElementById("route-lens-data").textContent);
              const select = document.getElementById("operation-select");
              const view = document.getElementById("operation-view");

              const element = (tag, className, value) => {
                const node = document.createElement(tag);
                if (className) node.className = className;
                if (value !== undefined && value !== null) node.textContent = String(value);
                return node;
              };
              const valueOrDash = value => value === undefined || value === null || value === "" ? "—" : value;

              function renderSummary(decision) {
                const summary = element("div", "operation-summary");
                [
                  ["Selected provider", valueOrDash(decision.selected_provider)],
                  ["Final outcome", valueOrDash(decision.simulated_result || decision.result)],
                  ["Latency", decision.latency_sec == null ? "—" : decision.latency_sec + " sec"],
                  ["Attempts considered", Array.isArray(decision.attempts) ? decision.attempts.length : 0]
                ].forEach(([label, value]) => {
                  const item = element("div", "summary-item");
                  item.append(element("small", "", label), element("strong", "", value));
                  summary.append(item);
                });
                return summary;
              }

              function renderLifecycle(attempt) {
                if (!attempt.state_reserved) return null;
                const details = document.createElement("details");
                details.append(element("summary", "", "Reservation lifecycle"));
                const wrap = element("div", "score-wrap");
                const table = document.createElement("table");
                table.setAttribute("aria-label", "Provider state before reservation, while reserved, and after settlement");
                const head = document.createElement("thead");
                const headRow = document.createElement("tr");
                ["Metric", "Before", "Reserved", "After"].forEach(label => headRow.append(element("th", "", label)));
                head.append(headRow);
                const body = document.createElement("tbody");
                [
                  ["in progress count", "in_progress_count"],
                  ["in progress amount", "in_progress_amount"],
                  ["available requisites", "available_requisites"],
                  ["daily approved amount", "daily_approved_amount"]
                ].forEach(([label, key]) => {
                  const row = document.createElement("tr");
                  row.append(
                    element("td", "", label),
                    element("td", "", valueOrDash(attempt.state_before && attempt.state_before[key])),
                    element("td", "", valueOrDash(attempt.state_reserved && attempt.state_reserved[key])),
                    element("td", "", valueOrDash(attempt.state_after && attempt.state_after[key]))
                  );
                  body.append(row);
                });
                table.append(head, body);
                wrap.append(table);
                details.append(wrap);
                return details;
              }

              function renderBreakdown(breakdown) {
                const details = document.createElement("details");
                const summary = element("summary", "", "Score breakdown");
                const wrap = element("div", "score-wrap");
                const table = document.createElement("table");
                table.setAttribute("aria-label", "Weighted policy score breakdown");
                const head = document.createElement("thead");
                const headRow = document.createElement("tr");
                ["Factor", "Raw", "Weight", "Contribution"].forEach(label => headRow.append(element("th", "", label)));
                head.append(headRow);
                const body = document.createElement("tbody");
                Object.entries(breakdown).forEach(([name, detail]) => {
                  const row = document.createElement("tr");
                  row.append(
                    element("td", "", name.replaceAll("_", " ")),
                    element("td", "", valueOrDash(detail && detail.raw)),
                    element("td", "", valueOrDash(detail && detail.weight)),
                    element("td", "", valueOrDash(detail && detail.contribution))
                  );
                  body.append(row);
                });
                table.append(head, body);
                wrap.append(table);
                details.append(summary, wrap);
                return details;
              }

              function renderAttempt(attempt, index, decision) {
                const card = element("article", "attempt");
                const head = element("div", "attempt-head");
                const status = valueOrDash(attempt.outcome || attempt.decision);
                const indexLabel = attempt.attempt_number ? "Attempt " + attempt.attempt_number : "Candidate check " + (index + 1);
                const statusClass = status === "skipped" ? "skipped" : (["rejected", "expired"].includes(status) ? "failed" : "");
                head.append(
                  element("span", "attempt-index", indexLabel),
                  element("h3", "", valueOrDash(attempt.provider)),
                  element("span", "badge " + statusClass, status)
                );
                card.append(head);
                const reason = [attempt.reason, attempt.details].filter(Boolean).join(" · ");
                card.append(element("p", "", reason || "No additional reason recorded."));
                const breakdown = attempt.score_breakdown ||
                  (attempt.provider === decision.selected_provider ? decision.score_breakdown : null);
                if (breakdown && Object.keys(breakdown).length) card.append(renderBreakdown(breakdown));
                const lifecycle = renderLifecycle(attempt);
                if (lifecycle) card.append(lifecycle);
                return card;
              }

              function renderOperation() {
                const decision = data.decisions.find(item => String(item.operation_id) === select.value);
                view.replaceChildren();
                if (!decision) {
                  view.append(element("p", "empty", "No operation data is available."));
                  return;
                }
                view.append(renderSummary(decision));
                if (decision.decision_summary) view.append(element("p", "decision-copy", decision.decision_summary));
                const unmet = Array.isArray(decision.unmet_goals) ? decision.unmet_goals : [];
                if (unmet.length) {
                  const copy = unmet.map(goal => `${goal.provider}: ${goal.goal} unavailable because ${goal.reason}`).join(" · ");
                  view.append(element("p", "decision-copy", "Unmet soft goals · " + copy));
                }
                const attempts = element("div", "attempts");
                const list = Array.isArray(decision.attempts) ? decision.attempts : [];
                if (list.length) list.forEach((attempt, index) => attempts.append(renderAttempt(attempt, index, decision)));
                else attempts.append(element("p", "empty", "No provider attempts were recorded."));
                view.append(attempts);
              }

              select.addEventListener("change", renderOperation);
              renderOperation();
            })();
          </script>
        </body>
        </html>
      HTML
      html.gsub(/[ \t]+$/, "")
    end

    private

    def h(value)
      value.to_s
           .gsub("&", "&amp;")
           .gsub("<", "&lt;")
           .gsub(">", "&gt;")
           .gsub('"', "&quot;")
           .gsub("'", "&#39;")
    end

    def number(value)
      value.nil? ? "0" : value.to_s
    end

    def percentage(value)
      "#{number(value)}%"
    end

    def period_label
      period = report["period"]
      period.nil? || period.to_s.empty? ? "Current routing run" : "Period #{period}"
    end

    def retry_count
      report.dig("routing_resilience", "retry_count") || report["retry_count"] || 0
    end

    def fallback_count
      report.dig("routing_resilience", "fallback_count") || report["fallback_count"] || 0
    end

    def outcome_note
      rejected = report.dig("outcomes", "rejected", "count") || 0
      expired = report.dig("outcomes", "expired", "count") || 0
      "#{rejected} rejected · #{expired} expired"
    end

    def attempt_failure_count
      (report.dig("attempt_outcomes", "rejected") || 0).to_i +
        (report.dig("attempt_outcomes", "expired") || 0).to_i
    end

    def recovery_note
      recovered = report.dig("attempt_outcomes", "recovered_operations") || 0
      rate = report.dig("attempt_outcomes", "recovery_rate_pct") || 0
      "#{recovered} recovered · #{rate}% recovery"
    end

    def kpi(label, value, note)
      <<~HTML.chomp
        <article class="card"><span class="kpi-label">#{h(label)}</span><strong class="kpi-value">#{h(value)}</strong><span class="kpi-note">#{h(note)}</span></article>
      HTML
    end

    def distribution_rows
      distribution = report["distribution"]
      return empty_message("No distribution metrics available.") unless distribution.is_a?(Hash) && !distribution.empty?

      distribution.map do |provider, metrics|
        metrics = {} unless metrics.is_a?(Hash)
        actual = bounded_percentage(metrics["share_pct"])
        target = bounded_percentage(metrics["target_pct"])
        delta = metrics["delta_pct"] || 0
        <<~HTML.chomp
          <div class="distribution-row">
            <span class="provider">#{h(provider)}</span>
            <div class="bar-pair" aria-label="#{h(provider)} actual #{actual}% and target #{target}%">
              <span class="track"><span class="fill" style="--value:#{actual}%"></span></span>
              <span class="track"><span class="fill target" style="--value:#{target}%"></span></span>
            </div>
            <span class="bar-values">#{actual}% / #{target}% · Δ #{signed(delta)} pp</span>
          </div>
        HTML
      end.join
    end

    def capacity_rows
      capacities = report["capacity_utilization"] || report["projected_daily_utilization"]
      return empty_message("No capacity metrics available.") unless capacities.is_a?(Hash) && !capacities.empty?

      capacities.map do |provider, metrics|
        metrics = {} unless metrics.is_a?(Hash)
        raw = metrics["utilization_pct"]
        value = raw.nil? ? 0 : bounded_percentage(raw)
        label = raw.nil? ? "Unbounded" : "#{value}%"
        headroom = metrics["headroom"]
        note = headroom.nil? ? "No configured daily ceiling" : "#{format_amount(headroom)} headroom"
        meter_attributes = if raw.nil?
                             "role=\"img\" aria-label=\"#{h(provider)} daily capacity is unbounded\""
                           else
                             "role=\"meter\" aria-label=\"#{h(provider)} daily capacity utilization\" aria-valuemin=\"0\" aria-valuemax=\"100\" aria-valuenow=\"#{value}\""
                           end
        <<~HTML.chomp
          <div>
            <div class="capacity-head"><strong>#{h(provider)}</strong><span>#{h(label)}</span></div>
            <div class="track" #{meter_attributes}><span class="fill" style="--value:#{value}%"></span></div>
            <div class="capacity-note">#{h(note)}</div>
          </div>
        HTML
      end.join
    end

    def recommendation_rows
      recommendations = report["recommendations"]
      recommendations = report["recommendation_details"] if !recommendations.is_a?(Array) || recommendations.empty?
      return empty_message("No recommendations were generated for this run.") unless recommendations.is_a?(Array) && !recommendations.empty?

      items = recommendations.map do |item|
        message = item.is_a?(Hash) ? item["message"] || item["expected_impact"] || item.inspect : item
        "<li>#{h(message)}</li>"
      end.join
      "<ol class=\"recommendations\">#{items}</ol>"
    end

    def policy_comparison_section
      comparison = report["policy_comparison"]
      return "" unless comparison.is_a?(Hash)

      scenarios = Array(comparison["scenarios"])
      rows = scenarios.map do |scenario|
        changed = Array(scenario["changed_operations_vs_balanced"]).length
        <<~HTML.chomp
          <tr>
            <td>#{h(scenario["name"])}</td>
            <td>#{h(scenario["policy"])}</td>
            <td>#{h(scenario["count_target_error_pp"])}</td>
            <td>#{h(scenario["volume_target_error_pp"])}</td>
            <td>#{h(changed)}</td>
          </tr>
        HTML
      end.join
      replay = comparison["recommendation_replay"]
      replay_copy = if replay.is_a?(Hash)
                      constrained_provider = replay.dig("recommendation", "provider").to_s
                      before = replay.dig("before", "count_target_error_pp")
                      after = replay.dig("after", "count_target_error_pp")
                      capacity_before = replay.dig("before", "capacity_utilization", constrained_provider, "utilization_pct")
                      capacity_after = replay.dig("after", "capacity_utilization", constrained_provider, "utilization_pct")
                      volume_delta = replay.dig("tradeoffs", "volume_target_error_change_pp")
                      targets = replay.dig("after", "traffic_targets") || {}
                      formatted = targets.map { |provider, value| "#{provider} #{value}%" }.join(", ")
                      "Recommendation replay: #{constrained_provider} utilization #{capacity_before}% → #{capacity_after}%; " \
                        "count-target error #{before} pp → #{after} pp; volume-target error changes by +#{volume_delta} pp. " \
                        "Temporary targets: #{formatted}."
                    else
                      "No safe recommendation replay was available for this run."
                    end

      <<~HTML.chomp
        <section class="card operation-card" aria-labelledby="policy-lab-title">
          <div class="eyebrow">Controlled replay</div>
          <h2 id="policy-lab-title">Policy lab</h2>
          <p>Every scenario uses the same queue with provider outcomes fixed to approved, isolating the effect of policy weights.</p>
          <div class="score-wrap">
            <table aria-label="Policy preset comparison">
              <thead><tr><th>Scenario</th><th>Policy</th><th>Count error, pp</th><th>Volume error, pp</th><th>Changed routes</th></tr></thead>
              <tbody>#{rows}</tbody>
            </table>
          </div>
          <p class="decision-copy">#{h(replay_copy)}</p>
        </section>
      HTML
    end

    def operation_options
      return "<option value=\"\">No operations</option>" if decisions.empty?

      decisions.map.with_index do |decision, index|
        id = decision.is_a?(Hash) ? decision["operation_id"] : nil
        label = id.nil? || id.to_s.empty? ? "Operation #{index + 1}" : id
        "<option value=\"#{h(label)}\">#{h(label)}</option>"
      end.join
    end

    def embedded_data
      JSON.generate("decisions" => decisions, "report" => report)
          .gsub("&", "\\u0026")
          .gsub("<", "\\u003c")
          .gsub(">", "\\u003e")
          .gsub("\u2028", "\\u2028")
          .gsub("\u2029", "\\u2029")
    end

    def bounded_percentage(value)
      number = Float(value)
      number = [[number, 0.0].max, 100.0].min
      number == number.to_i ? number.to_i : number.round(2)
    rescue ArgumentError, TypeError
      0
    end

    def signed(value)
      number = Float(value)
      formatted = number == number.to_i ? number.to_i.to_s : number.round(2).to_s
      number.positive? ? "+#{formatted}" : formatted
    rescue ArgumentError, TypeError
      "0"
    end

    def format_amount(value)
      amount = Float(value)
      formatted = amount == amount.to_i ? amount.to_i.to_s : amount.round(2).to_s
      "#{formatted.reverse.scan(/.{1,3}/).join(' ').reverse} RUB"
    rescue ArgumentError, TypeError
      "Unknown"
    end

    def empty_message(message)
      "<p class=\"empty\">#{h(message)}</p>"
    end
  end
end
