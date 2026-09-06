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
  // Словари подписей приезжают из Ruby внутри встроенного JSON: единственный
  // источник правды живёт в Observatory, а не в двух копиях на двух языках.
  // Object.create(null) убирает прототип, поэтому коды вида "constructor"
  // из входных данных не подменяют подпись функцией.
  const labelMap = source => Object.assign(Object.create(null), source && typeof source === "object" ? source : {});
  const labels = data.labels || {};
  const outcomeLabels = labelMap(labels.outcomes);
  const reasonLabels = labelMap(labels.reasons);
  const factorLabels = labelMap(labels.factors);
  // Неизвестный код (новое правило допуска, новый фактор скоринга) не должен
  // ломать вывод: показываем читаемый snake_case вместо сырого значения.
  const humanize = value => String(value).replaceAll("_", " ");
  const labelFor = (map, value) => {
    const known = map[value];
    if (typeof known === "string" && known) return known;
    return value === undefined || value === null || value === "" ? "—" : humanize(value);
  };
  const outcomeLabel = value => labelFor(outcomeLabels, value);
  const reasonLabel = value => labelFor(reasonLabels, value);

  function decisionSummary(decision) {
    const supplied = typeof decision.decision_summary === "string" ? decision.decision_summary.trim() : "";
    if (supplied) return supplied;

    const attempts = Array.isArray(decision.attempts) ? decision.attempts.filter(item => item.outcome) : [];
    if (!attempts.length && !decision.selected_provider) return "Ни один провайдер не смог принять выплату.";
    if (!attempts.length) return `Выбран маршрут ${valueOrDash(decision.selected_provider)}.`;
    if (attempts.length === 1) return `Выплата завершена через ${attempts[0].provider}: ${outcomeLabel(attempts[0].outcome)}.`;
    const chain = attempts.map(item => `${item.provider}: ${outcomeLabel(item.outcome)}`).join("; ");
    return `Маршрут восстановления: ${chain}.`;
  }

  function renderSummary(decision) {
    const summary = element("div", "operation-summary");
    [
      ["Выбранный провайдер", valueOrDash(decision.selected_provider)],
      ["Итог", outcomeLabel(decision.simulated_result || decision.result)],
      ["Задержка", decision.latency_sec == null ? "—" : decision.latency_sec + " с"],
      ["Проверено кандидатов", Array.isArray(decision.attempts) ? decision.attempts.length : 0]
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
    details.append(element("summary", "", "Жизненный цикл резервирования"));
    const wrap = element("div", "score-wrap");
    const table = document.createElement("table");
    table.setAttribute("aria-label", "Состояние провайдера до резервирования, во время него и после завершения");
    const head = document.createElement("thead");
    const headRow = document.createElement("tr");
    ["Метрика", "До", "Резерв", "После"].forEach(label => headRow.append(element("th", "", label)));
    head.append(headRow);
    const body = document.createElement("tbody");
    [
      ["Незавершённые операции", "in_progress_count"],
      ["Сумма незавершённых операций", "in_progress_amount"],
      ["Доступные реквизиты", "available_requisites"],
      ["Одобрено за день", "daily_approved_amount"]
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
    const summary = element("summary", "", "Разложение итоговой оценки");
    const wrap = element("div", "score-wrap");
    const table = document.createElement("table");
    table.setAttribute("aria-label", "Разложение взвешенной оценки политики");
    const head = document.createElement("thead");
    const headRow = document.createElement("tr");
    ["Фактор", "Значение", "Вес", "Вклад"].forEach(label => headRow.append(element("th", "", label)));
    head.append(headRow);
    const body = document.createElement("tbody");
    Object.entries(breakdown).forEach(([name, detail]) => {
      const row = document.createElement("tr");
      row.append(
        element("td", "", labelFor(factorLabels, name)),
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
    const rawStatus = attempt.outcome || attempt.decision;
    const status = outcomeLabel(rawStatus);
    const indexLabel = attempt.attempt_number ? "Попытка " + attempt.attempt_number : "Проверка кандидата " + (index + 1);
    const statusClass = rawStatus === "skipped" ? "skipped" : (["rejected", "expired"].includes(rawStatus) ? "failed" : "");
    head.append(
      element("span", "attempt-index", indexLabel),
      element("h3", "", valueOrDash(attempt.provider)),
      element("span", "badge " + statusClass, status)
    );
    card.append(head);
    const reason = attempt.reason ? `${reasonLabel(attempt.reason)} (${attempt.reason})` : "Дополнительная причина не указана.";
    card.append(element("p", "", reason));
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
      view.append(element("p", "empty", "Данные об операции отсутствуют."));
      return;
    }
    view.append(renderSummary(decision));
    view.append(element("p", "decision-copy", decisionSummary(decision)));
    const unmet = Array.isArray(decision.unmet_goals) ? decision.unmet_goals : [];
    if (unmet.length) {
      const copy = unmet.map(goal => `${goal.provider}: цель ${goal.goal}, причина ${reasonLabel(goal.reason)} (${goal.reason})`).join(" · ");
      view.append(element("p", "decision-copy", "Недостижимые мягкие цели · " + copy));
    }
    const attempts = element("div", "attempts");
    const list = Array.isArray(decision.attempts) ? decision.attempts : [];
    if (list.length) list.forEach((attempt, index) => attempts.append(renderAttempt(attempt, index, decision)));
    else attempts.append(element("p", "empty", "Попытки обращения к провайдерам не зафиксированы."));
    view.append(attempts);
  }

  select.addEventListener("change", renderOperation);
  renderOperation();
})();
