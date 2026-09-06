# frozen_string_literal: true

require "json"
require_relative "router"

module RouteLens
  # Генерирует переносимое представление сохранённых артефактов без зависимостей.
  # Динамический текст выводится через DOM textContent, а встроенный JSON
  # экранирует HTML-символы, поэтому входные данные не становятся разметкой.
  # Разметка, стили и скрипт лежат рядом в observatory/ и встраиваются в один
  # файл при генерации: страница остаётся автономной, но Ruby больше не хранит
  # внутри себя фронтенд.
  class Observatory
    class InputError < StandardError; end

    ASSET_DIR = File.expand_path("observatory", __dir__)
    private_constant :ASSET_DIR

    # Плейсхолдер намеренно узкий: только заглавные буквы и подчёркивания,
    # чтобы произвольный текст из данных не выглядел как метка подстановки.
    PLACEHOLDER = /\{\{([A-Z_]+)\}\}/
    private_constant :PLACEHOLDER

    # Подписи исходов попыток: значения приходят из OutcomeSimulator и роутера.
    OUTCOME_LABELS = {
      "approved" => "одобрено",
      "rejected" => "отклонено",
      "expired" => "истекло",
      "selected" => "выбран",
      "skipped" => "не выбран"
    }.freeze

    # Коды причин рождаются в Eligibility::Rules и в самом роутере. Раньше их
    # перевод жил копией внутри JavaScript и молча отставал от Ruby; теперь
    # словарь один, а тест сверяет его с исходниками правил и роутера.
    REASON_LABELS = {
      "provider_inactive" => "провайдер неактивен",
      "self_provider_reserved_for_fallback" => "собственный провайдер зарезервирован для fallback",
      "traffic_disabled" => "маршрут отключён нулевой долей трафика",
      "amount_below_minimum" => "сумма ниже минимума",
      "amount_exceeds_limit" => "сумма выше максимума",
      "daily_amount_limit_exceeded" => "превышен дневной лимит суммы",
      "in_progress_count_limit_exceeded" => "превышен лимит незавершённых операций",
      "in_progress_amount_limit_exceeded" => "превышен лимит суммы незавершённых операций",
      "bank_not_in_list" => "банк не поддерживается",
      "bank_excluded" => "банк исключён",
      "negative_margin_not_allowed" => "отрицательная маржа запрещена",
      "no_available_requisites" => "нет доступных реквизитов",
      "rate_limit_exceeded" => "превышен минутный лимит запросов",
      "lower_policy_score" => "оценка политики ниже",
      "state_changed_during_selection" => "состояние изменилось до резервирования",
      "external_pool_exhausted" => "внешние маршруты исчерпаны",
      "no_provider_available" => "нет доступного провайдера",
      "highest_policy_score" => "наивысшая оценка политики",
      "only_eligible_provider" => "единственный допустимый провайдер"
    }.freeze

    # Набор ключей берём у роутера: новый фактор скоринга сразу появится в
    # разложении оценки. Без перевода он покажет английскую подпись движка,
    # а не сырой snake_case.
    FACTOR_LABELS = Router::FACTOR_LABELS.merge(
      "count_target_gain" => "Баланс доли операций",
      "volume_target_gain" => "Баланс денежного объёма",
      "conversion" => "Конверсия",
      "priority" => "Приоритет каскада",
      "amount_preference" => "Предпочтительный диапазон суммы",
      "capacity" => "Запас ёмкости",
      "turnover_obligation" => "Обязательство по обороту",
      "load" => "Текущая нагрузка",
      "latency" => "Задержка",
      "cost" => "Стоимость"
    ).freeze

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
      html = fill(
        asset("page.html"),
        "STYLES" => inline_asset("page.css", 4),
        "SCRIPT" => inline_asset("page.js", 4),
        "PERIOD_LABEL" => h(period_label),
        "KPI_OPERATIONS" => kpi("Операции", number(report["total_operations"] || decisions.length), "обработано в этом запуске"),
        "KPI_APPROVAL" => kpi("Итоговое одобрение", percentage(report.dig("outcomes", "approval_rate_pct")), outcome_note),
        "KPI_FAILURES" => kpi("Сбои провайдеров", number(attempt_failure_count), recovery_note),
        "KPI_RETRIES" => kpi("Повторные попытки", number(retry_count), "по всем операциям"),
        "KPI_FALLBACK" => kpi("Fallback", number(fallback_count), "на собственного провайдера"),
        "DISTRIBUTION_ROWS" => distribution_rows,
        "CAPACITY_ROWS" => capacity_rows,
        "RECOMMENDATION_ROWS" => recommendation_rows,
        "POLICY_COMPARISON" => policy_comparison_section,
        "OPERATION_OPTIONS" => operation_options,
        "EMBEDDED_DATA" => embedded_data
      )
      html.gsub(/[ \t]+$/, "")
    end

    private

    # Один проход gsub: подставленный текст больше не сканируется, поэтому
    # данные не могут породить новый плейсхолдер. Блочная форма обязательна —
    # строковая замена трактовала бы \\ и \& внутри JSON как обратные ссылки.
    # fetch падает на незнакомой метке, так что опечатка в шаблоне видна сразу.
    def fill(template, values)
      template.gsub(PLACEHOLDER) { values.fetch(Regexp.last_match(1)).to_s }
    end

    def asset(name)
      File.read(File.join(ASSET_DIR, name))
    end

    # Строки таблиц склеиваются встык, поэтому завершающий перевод строки из
    # файла убираем — иначе разметка разъедется относительно прежней вёрстки.
    def fragment(name)
      asset(name).chomp
    end

    # Стили и скрипт хранятся без отступа. Выравниваем их по месту вставки,
    # чтобы итоговая разметка осталась такой же, как до выноса в файлы.
    def inline_asset(name, width)
      padding = " " * width
      asset(name).chomp.lines.map { |line| line.strip.empty? ? line : padding + line }.join
    end

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
      period.nil? || period.to_s.empty? ? "Текущий запуск маршрутизации" : "Период #{period}"
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
      "#{rejected} отклонено · #{expired} истекло"
    end

    def attempt_failure_count
      (report.dig("attempt_outcomes", "rejected") || 0).to_i +
        (report.dig("attempt_outcomes", "expired") || 0).to_i
    end

    def recovery_note
      recovered = report.dig("attempt_outcomes", "recovered_operations") || 0
      rate = report.dig("attempt_outcomes", "recovery_rate_pct") || 0
      "#{recovered} восстановлено · #{rate}% восстановление"
    end

    def kpi(label, value, note)
      "<article class=\"card\"><span class=\"kpi-label\">#{h(label)}</span>" \
        "<strong class=\"kpi-value\">#{h(value)}</strong>" \
        "<span class=\"kpi-note\">#{h(note)}</span></article>"
    end

    def distribution_rows
      distribution = report["distribution"]
      return empty_message("Метрики распределения отсутствуют.") unless distribution.is_a?(Hash) && !distribution.empty?

      distribution.map do |provider, metrics|
        metrics = {} unless metrics.is_a?(Hash)
        actual = bounded_percentage(metrics["share_pct"])
        target = bounded_percentage(metrics["target_pct"])
        delta = metrics["delta_pct"] || 0
        fill(
          fragment("row_distribution.html"),
          "PROVIDER" => h(provider),
          "ACTUAL" => actual,
          "TARGET" => target,
          "DELTA" => signed(delta)
        )
      end.join
    end

    def capacity_rows
      capacities = report["capacity_utilization"] || report["projected_daily_utilization"]
      return empty_message("Метрики ёмкости отсутствуют.") unless capacities.is_a?(Hash) && !capacities.empty?

      capacities.map do |provider, metrics|
        metrics = {} unless metrics.is_a?(Hash)
        raw = metrics["utilization_pct"]
        value = raw.nil? ? 0 : bounded_percentage(raw)
        label = raw.nil? ? "Без лимита" : "#{value}%"
        headroom = metrics["headroom"]
        note = headroom.nil? ? "Дневной лимит не задан" : "Запас: #{format_amount(headroom)}"
        meter_attributes = if raw.nil?
                             "role=\"img\" aria-label=\"#{h(provider)}: дневная ёмкость без лимита\""
                           else
                             "role=\"meter\" aria-label=\"#{h(provider)}: использование дневной ёмкости\" aria-valuemin=\"0\" aria-valuemax=\"100\" aria-valuenow=\"#{value}\""
                           end
        fill(
          fragment("row_capacity.html"),
          "PROVIDER" => h(provider),
          "LABEL" => h(label),
          # Атрибуты доступности собраны выше и уже экранированы: это готовая
          # разметка, поэтому в шаблон она уходит без повторного экранирования.
          "METER_ATTRIBUTES" => meter_attributes,
          "VALUE" => value,
          "NOTE" => h(note)
        )
      end.join
    end

    def recommendation_rows
      recommendations = report["recommendation_details"]
      recommendations = report["recommendations"] if !recommendations.is_a?(Array) || recommendations.empty?
      return empty_message("Для этого запуска рекомендации не сформированы.") unless recommendations.is_a?(Array) && !recommendations.empty?

      items = recommendations.map do |item|
        message = item.is_a?(Hash) ? localized_recommendation(item) : item
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
        fill(
          fragment("row_policy_scenario.html"),
          "NAME" => h(localized_scenario_name(scenario["name"])),
          "POLICY" => h(scenario["policy"]),
          "COUNT_ERROR" => h(scenario["count_target_error_pp"]),
          "VOLUME_ERROR" => h(scenario["volume_target_error_pp"]),
          "CHANGED" => h(changed)
        )
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
                      "Повтор с рекомендацией: использование ёмкости #{constrained_provider} меняется с #{capacity_before}% до #{capacity_after}%; " \
                        "ошибка долей операций с #{before} до #{after} п.п.; ошибка долей объёма меняется на +#{volume_delta} п.п. " \
                        "Временные цели: #{formatted}."
                    else
                      "Безопасный повтор с рекомендацией для этого запуска недоступен."
                    end

      fill(
        fragment("section_policy_lab.html"),
        "ROWS" => rows,
        "REPLAY_COPY" => h(replay_copy)
      )
    end

    def operation_options
      return "<option value=\"\">Нет операций</option>" if decisions.empty?

      decisions.map.with_index do |decision, index|
        id = decision.is_a?(Hash) ? decision["operation_id"] : nil
        label = id.nil? || id.to_s.empty? ? "Операция #{index + 1}" : id
        "<option value=\"#{h(label)}\">#{h(label)}</option>"
      end.join
    end

    # Словари едут вместе с данными в том же экранированном JSON: скрипт
    # страницы только читает их, поэтому переводы не дублируются в JS.
    def label_catalog
      {
        "outcomes" => OUTCOME_LABELS,
        "reasons" => REASON_LABELS,
        "factors" => FACTOR_LABELS
      }
    end

    def embedded_data
      JSON.generate("decisions" => decisions, "report" => report, "labels" => label_catalog)
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
      "#{formatted.reverse.scan(/.{1,3}/).join(' ').reverse} ₽"
    rescue ArgumentError, TypeError
      "Неизвестно"
    end

    def localized_recommendation(item)
      provider = item["provider"] || "Провайдер"
      evidence = item["evidence"].is_a?(Hash) ? item["evidence"] : {}
      action = item["action"].is_a?(Hash) ? item["action"] : {}

      case item["type"]
      when "capacity_pressure"
        "#{provider}: дневной лимит использован на #{evidence['utilization_pct']}% " \
          "(#{format_amount(evidence['used'])} из #{format_amount(evidence['limit'])}, запас #{format_amount(evidence['headroom'])}). " \
          "Временно изменить traffic_percentage с #{action['current']}% до #{action['proposed']}% до сброса дневного лимита."
      when "conversion_drift"
        "#{provider}: conversion_24h #{evidence['conversion_24h_pct']}% против исторического одобрения " \
          "#{evidence['historical_approval_rate_pct']}% (разница #{signed(evidence['difference_pp'])} п.п., n=#{evidence['historical_operations']}). " \
          "Временно снизить вес policy.weights.conversion с #{action['current']} до #{action['proposed']} до согласования окон метрик."
      when "count_share_deviation"
        exclusions = evidence["hard_exclusion_count"].to_i
        exclusion_note = exclusions.positive? ? " Жёстких исключений: #{exclusions}." : ""
        "#{provider}: фактическая доля операций #{evidence['actual_share_pct']}% при цели #{evidence['target_pct']}% " \
          "(отклонение #{signed(evidence['delta_pct'])} п.п.).#{exclusion_note} " \
          "Сохранить traffic_percentage #{action['proposed']}% и проверить допустимый состав провайдеров перед изменением бизнес-цели."
      else
        item["message"] || item["expected_impact"] || "Рекомендация сформирована по текущим метрикам."
      end
    end

    def localized_scenario_name(name)
      {
        "balanced" => "Сбалансированная",
        "conversion_first" => "Приоритет конверсии",
        "cascade" => "Приоритет каскада",
        "capacity_first" => "Приоритет ёмкости",
        "recommended_targets" => "Рекомендуемые цели"
      }.fetch(name.to_s, name)
    end

    def empty_message(message)
      "<p class=\"empty\">#{h(message)}</p>"
    end
  end
end
