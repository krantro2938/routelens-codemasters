# frozen_string_literal: true

require "time"

require_relative "eligibility/evaluator"
require_relative "outcome_simulator"
require_relative "scoring/policy"

module RouteLens
  class RoutingError < StandardError; end

  RunResult = Struct.new(:decisions, :provider_states, :routing_metrics, keyword_init: true)

  # Управляет полным маршрутом операции: допустимостью, скорингом, резервом,
  # результатом и повтором. Изменяемые лимиты принадлежат ProviderState,
  # а распределение текущего пакета — Router.
  class Router
    # Ключи — машинные имена факторов скоринга и частью контракта остаются
    # английскими: их читает score_breakdown и Observatory::FACTOR_LABELS.
    # Значения — человекочитаемые подписи, они подставляются в русскую фразу
    # selection_details, поэтому даны строчными буквами и в именительном падеже.
    FACTOR_LABELS = {
      "count_target_gain" => "баланс доли операций",
      "volume_target_gain" => "баланс денежного объёма",
      "conversion" => "конверсия",
      "priority" => "приоритет каскада",
      "amount_preference" => "предпочтительный диапазон суммы",
      "capacity" => "запас ёмкости",
      "turnover_obligation" => "обязательство по обороту",
      "load" => "текущая нагрузка",
      "latency" => "задержка",
      "cost" => "стоимость провайдера"
    }.freeze

    # Коды результата остаются английскими в полях simulated_result и outcome —
    # на них смотрит валидатор. Здесь они переводятся только для связного
    # русского текста decision_summary.
    OUTCOME_LABELS = {
      "approved" => "одобрено",
      "rejected" => "отказ",
      "expired" => "истекло"
    }.freeze

    attr_reader :providers, :policy

    def initialize(providers:, policy:, simulator: OutcomeSimulator.new, evaluator: Eligibility::Evaluator.new)
      @providers = providers
      @policy = policy
      @simulator = simulator
      @evaluator = evaluator
      @provider_by_name = providers.to_h { |provider| [provider.payment_system, provider] }
      # Эти метрики описывают только финальное назначение каждой выплаты и
      # поэтому используются для приближения к целевым долям.
      #
      # Внешний под-реестр обязателен: цели (count_targets, volume_targets)
      # заданы только для внешних провайдеров и в сумме дают 100%. Если считать
      # долю от всех назначений, то каждый уход во внутренний spacepayments
      # навсегда занижает доли внешних, и скоринг гонится за недостижимой целью.
      @metrics = {
        count_by_provider: Hash.new(0),
        volume_by_provider: Hash.new(0.0),
        total_count: 0,
        total_volume: 0.0,
        external_count_by_provider: Hash.new(0),
        external_volume_by_provider: Hash.new(0.0),
        external_count: 0,
        external_volume: 0.0,
        fallback_count: 0,
        fallback_volume: 0.0,
        unroutable_count: 0,
        count_targets: external_providers.to_h do |provider|
          [provider.payment_system, provider["traffic_percentage"].to_f]
        end
      }
      # Неудачные вызовы учитываются отдельно: они важны для нагрузки и RPM,
      # но не должны считаться выполненной долей маршрутизации.
      @attempt_metrics = {
        count_by_provider: Hash.new(0),
        volume_by_provider: Hash.new(0.0),
        total_count: 0,
        total_volume: 0.0
      }
    end

    def route(operations)
      decisions = operations.map { |operation| route_operation(operation) }
      RunResult.new(
        decisions: decisions,
        provider_states: providers.to_h { |provider| [provider.payment_system, provider.snapshot] },
        routing_metrics: serializable_metrics
      )
    end

    private

    def route_operation(operation)
      operation_id = operation.fetch("operation_id")
      amount = operation.fetch("amount").to_f
      attempts = []
      attempted_names = []
      selected_attempts = []
      final_provider = nil
      final_outcome = nil
      final_score = nil
      round = 0

      append_initial_hard_exclusions(attempts, operation)

      loop do
        # После каждой неудачи список строится заново по текущему состоянию:
        # резерв предыдущей попытки уже снят, а лимиты могли измениться.
        candidates = current_external_candidates(operation, attempted_names)
        break if candidates.empty?

        round += 1
        ranking = policy.rank(
          candidates: candidates,
          states: @provider_by_name,
          operation: operation,
          metrics: scoring_metrics
        )
        chosen_entry = ranking.first
        provider = chosen_entry.fetch(:provider)
        score = chosen_entry.fetch(:result)
        reservation_id = "#{operation_id}:#{selected_attempts.length + 1}:#{provider.payment_system}"
        state_before = provider.snapshot

        begin
          provider.reserve!(
            amount,
            reservation_id: reservation_id,
            at: operation["created_at"] || Time.now
          )
        rescue StateError => e
          # Между скорингом и резервом ёмкость могла измениться. Повторная
          # проверка внутри ProviderState закрывает эту гонку безопасным skip.
          attempted_names << provider.payment_system
          attempts << {
            "provider" => provider.payment_system,
            "decision" => "skipped",
            "reason" => "state_changed_during_selection",
            # Сообщение ProviderState остаётся полуструктурированной уликой
            # («quickpay in-progress count limit exceeded: 11 > 10»),
            # поэтому переводится только объясняющая его рамка.
            "details" => "Состояние изменилось между скорингом и резервированием: #{e.message}",
            "stage" => "selection",
            "round" => round
          }
          next
        end

        state_reserved = provider.snapshot

        outcome = @simulator.call(operation, provider)
        settle(provider, outcome.fetch("result"), reservation_id)
        record_provider_attempt(provider.payment_system, amount)
        attempted_names << provider.payment_system

        attempt = {
          "provider" => provider.payment_system,
          "decision" => "selected",
          "reason" => candidates.one? ? "only_eligible_provider" : "highest_policy_score",
          "details" => selection_details(score, ranking),
          "stage" => "selection",
          "round" => round,
          "rank" => 1,
          "score" => score.fetch(:total),
          "score_breakdown" => stringify(score.fetch(:breakdown)),
          "outcome" => outcome.fetch("result"),
          "latency_sec" => outcome.fetch("latency_sec"),
          "state_before" => state_before,
          "state_reserved" => state_reserved,
          "state_after" => provider.snapshot
        }
        approved = outcome.fetch("result") == "approved"
        if approved
          # Проигравшие кандидаты оценены тем же ранжированием, что и победитель,
          # то есть ДО того, как стал известен его результат. Пишем их перед
          # выбранной попыткой, иначе журнал читается так, будто их рассматривали
          # уже после успешной выплаты.
          append_lower_ranked_candidates(attempts, ranking.drop(1), attempted_names, round)
        end
        attempts << attempt
        selected_attempts << attempt

        if approved
          final_provider = provider
          final_outcome = outcome
          final_score = score
          break
        end
      end

      unless final_provider
        round += 1
        begin
          # Внутренний провайдер рассматривается только после исчерпания внешних,
          # поэтому он не может случайно выиграть обычный мягкий скоринг.
          provider, outcome, fallback_attempt = execute_fallback(operation, selected_attempts.length + 1, round)
          attempts << fallback_attempt
          selected_attempts << fallback_attempt
          final_provider = provider
          final_outcome = outcome
        rescue RoutingError => e
          # Одна невыполнимая выплата не должна уничтожать весь пакет: пишем
          # корректную запись решения с сохранённым следом отказов и продолжаем.
          return unroutable_decision(operation_id, attempts, round, e)
        end
      end

      record_routing_assignment(final_provider.payment_system, amount)

      selected_attempts.each_with_index do |attempt, index|
        attempt["attempt_number"] = index + 1
        attempt["final"] = index == selected_attempts.length - 1
      end

      {
        "operation_id" => operation_id,
        "selected_provider" => final_provider.payment_system,
        "attempts" => attempts,
        "simulated_result" => final_outcome.fetch("result"),
        "latency_sec" => selected_attempts.sum { |attempt| attempt.fetch("latency_sec", 0).to_i },
        "policy" => policy.name,
        "decision_summary" => decision_summary(selected_attempts, final_provider),
        "score_breakdown" => final_score ? stringify(final_score.fetch(:breakdown)) : {},
        "routing_sequence" => selected_attempts.map { |attempt| attempt.fetch("provider") },
        "unmet_goals" => unmet_goals_for(attempts)
      }
    end

    # Запись для операции, которую не принял ни один провайдер, включая
    # внутренний. Формат остаётся валидным для валидатора организаторов:
    # спецификация допускает только approved/rejected/expired, поэтому
    # неисполненная выплата честнее всего описывается как expired.
    def unroutable_decision(operation_id, attempts, round, error)
      @metrics[:unroutable_count] += 1
      attempts << {
        "provider" => nil,
        "decision" => "skipped",
        "reason" => "no_provider_available",
        "details" => error.message,
        "stage" => "fallback",
        "round" => round
      }

      {
        "operation_id" => operation_id,
        "selected_provider" => nil,
        "attempts" => attempts,
        "simulated_result" => "expired",
        "latency_sec" => 0,
        "policy" => policy.name,
        "decision_summary" => "Ни один провайдер не смог принять выплату: #{error.message}",
        "score_breakdown" => {},
        "routing_sequence" => [],
        "unmet_goals" => unmet_goals_for(attempts)
      }
    end

    def append_initial_hard_exclusions(attempts, operation)
      external_providers.each do |provider|
        evaluation = @evaluator.evaluate(provider, operation)
        next if evaluation.eligible?

        attempts << exclusion_attempt(provider, evaluation)
      end
    end

    def current_external_candidates(operation, attempted_names)
      external_providers.reject { |provider| attempted_names.include?(provider.payment_system) }
                        .select { |provider| @evaluator.eligible?(provider, operation) }
    end

    def exclusion_attempt(provider, evaluation)
      {
        "provider" => provider.payment_system,
        "decision" => "skipped",
        "reason" => evaluation.reason,
        "details" => evaluation.details,
        # Жёсткий отсев выполняется до первого ранжирования, поэтому раунд 0.
        "stage" => "eligibility_screen",
        "round" => 0,
        "all_reasons" => evaluation.failures.map(&:to_h)
      }
    end

    def append_lower_ranked_candidates(attempts, ranking, attempted_names, round)
      ranking.each_with_index do |entry, index|
        provider = entry.fetch(:provider)
        next if attempted_names.include?(provider.payment_system)

        result = entry.fetch(:result)
        attempts << {
          "provider" => provider.payment_system,
          "decision" => "skipped",
          "reason" => "lower_policy_score",
          "details" => "оценка #{result.fetch(:total)} ниже оценки выбранного провайдера",
          "stage" => "policy_ranking",
          "round" => round,
          "rank" => index + 2,
          "score" => result.fetch(:total),
          "score_breakdown" => stringify(result.fetch(:breakdown))
        }
      end
    end

    def execute_fallback(operation, sequence, round)
      provider = self_provider
      raise RoutingError, "Внутренний провайдер для резервного маршрута не настроен" unless provider

      evaluation = @evaluator.evaluate(provider, operation, context: { fallback: true })
      unless evaluation.eligible?
        # reason — машинный код причины и остаётся английским.
        raise RoutingError, "Резервный провайдер #{provider.payment_system} недоступен: #{evaluation.reason}"
      end

      reservation_id = "#{operation.fetch('operation_id')}:#{sequence}:#{provider.payment_system}"
      state_before = provider.snapshot
      provider.reserve!(
        operation.fetch("amount"),
        reservation_id: reservation_id,
        at: operation["created_at"] || Time.now
      )
      state_reserved = provider.snapshot
      outcome = @simulator.call(operation, provider)
      settle(provider, outcome.fetch("result"), reservation_id)
      record_provider_attempt(provider.payment_system, operation.fetch("amount").to_f)

      attempt = {
        "provider" => provider.payment_system,
        "decision" => "selected",
        "reason" => "external_pool_exhausted",
        "details" => "все допустимые внешние провайдеры недоступны или завершились неудачей",
        "stage" => "fallback",
        "round" => round,
        "outcome" => outcome.fetch("result"),
        "latency_sec" => outcome.fetch("latency_sec"),
        "state_before" => state_before,
        "state_reserved" => state_reserved,
        "state_after" => provider.snapshot
      }

      [provider, outcome, attempt]
    rescue StateError => e
      raise RoutingError, "Не удалось зарезервировать резервного провайдера: #{e.message}"
    end

    def settle(provider, result, reservation_id)
      case result
      when "approved" then provider.approve!(reservation_id: reservation_id)
      when "rejected" then provider.reject!(reservation_id: reservation_id)
      when "expired" then provider.expire!(reservation_id: reservation_id)
      else raise RoutingError, "Неизвестный результат: #{result}"
      end
    end

    def record_provider_attempt(provider_name, amount)
      @attempt_metrics[:count_by_provider][provider_name] += 1
      @attempt_metrics[:volume_by_provider][provider_name] += amount
      @attempt_metrics[:total_count] += 1
      @attempt_metrics[:total_volume] += amount
    end

    # Цели количества и объёма относятся к финальному распределению из отчёта.
    # Неудачные вызовы видны в метриках попыток, но не могут ложно закрыть цель.
    def record_routing_assignment(provider_name, amount)
      @metrics[:count_by_provider][provider_name] += 1
      @metrics[:volume_by_provider][provider_name] += amount
      @metrics[:total_count] += 1
      @metrics[:total_volume] += amount

      provider = @provider_by_name[provider_name]
      if provider&.self_provider?
        @metrics[:fallback_count] += 1
        @metrics[:fallback_volume] += amount
      else
        @metrics[:external_count_by_provider][provider_name] += 1
        @metrics[:external_volume_by_provider][provider_name] += amount
        @metrics[:external_count] += 1
        @metrics[:external_volume] += amount
      end
    end

    def scoring_metrics
      # Компоненты долей получают единый снимок уже завершённых назначений;
      # текущая операция добавляется каждым компонентом только виртуально.
      # Знаменатель — только внешние назначения: fallback не участвует в целевом
      # распределении и попадает в отчёт отдельной строкой fallback_share_pct.
      {
        count_by_provider: @metrics[:external_count_by_provider],
        volume_by_provider: @metrics[:external_volume_by_provider],
        total_count: @metrics[:external_count],
        total_volume: @metrics[:external_volume],
        count_targets: @metrics[:count_targets],
        providers: external_providers
      }
    end

    def selection_details(score, ranking)
      runner = ranking[1]&.fetch(:result)
      return "Единственный провайдер, оставшийся после жёстких ограничений." unless runner

      chosen_breakdown = score.fetch(:breakdown)
      runner_breakdown = runner.fetch(:breakdown)
      advantages = chosen_breakdown.filter_map do |name, entry|
        delta = entry.fetch(:contribution) - runner_breakdown.fetch(name, {}).fetch(:contribution, 0.0)
        [name, delta] if delta > 0.01
      end.sort_by { |_name, delta| -delta }.first(2)
      drivers = advantages.map { |name, delta| "#{FACTOR_LABELS.fetch(name, name)} (+#{numeric(delta)})" }
      because = drivers.empty? ? "суммарная оценка политики оказалась выше" : drivers.join(" и ")
      "Выбран, потому что #{because}; оценка #{score.fetch(:total)} против #{runner.fetch(:total)}."
    end

    def decision_summary(selected_attempts, final_provider)
      failures = selected_attempts.count { |attempt| %w[rejected expired].include?(attempt["outcome"]) }
      if failures.positive?
        sequence = selected_attempts.map do |attempt|
          "#{attempt['provider']} — #{OUTCOME_LABELS.fetch(attempt['outcome'], attempt['outcome'])}"
        end.join("; ")
        "Маршрут восстановлен после #{failures} #{failed_attempt_word(failures)}: #{sequence}."
      else
        details = selected_attempts.last&.fetch("details", nil)
        "Выплату исполнил #{final_provider.payment_system}. #{details}".strip
      end
    end

    # Русское числительное требует согласования: «после 1 неудачной попытки»,
    # но «после 2 неудачных попыток». Формы 11..14 — исключение из правила
    # для единицы, поэтому проверяются два остатка, а не один.
    def failed_attempt_word(count)
      count % 10 == 1 && count % 100 != 11 ? "неудачной попытки" : "неудачных попыток"
    end

    def unmet_goals_for(attempts)
      return [] unless @metrics[:external_count].positive?

      # Фиксируем только недобор цели из-за жёсткого ограничения. Превышение
      # цели не является невыполненной целью и не должно попадать в объяснение.
      # Доли считаются от внешних назначений — так же, как их считает скоринг.
      attempts.flat_map do |attempt|
        next [] unless attempt["decision"] == "skipped"
        next [] if %w[lower_policy_score state_changed_during_selection].include?(attempt["reason"])

        provider = @provider_by_name[attempt["provider"]]
        next [] unless provider && !provider.self_provider?

        name = provider.payment_system
        goals = []
        count_target = provider["traffic_percentage"].to_f
        count_share = @metrics[:external_count_by_provider][name] * 100.0 / @metrics[:external_count]
        if count_share + 0.01 < count_target
          goals << unmet_goal("count_share_target", name, count_target, count_share, attempt)
        end

        # Объём — вторая измеряемая цель задания и обычно проседает сильнее,
        # поэтому недобор по деньгам объясняется отдельной записью.
        if @metrics[:external_volume].positive?
          volume_target = volume_target_for(provider)
          volume_share = @metrics[:external_volume_by_provider][name] * 100.0 / @metrics[:external_volume]
          if volume_share + 0.01 < volume_target
            goals << unmet_goal("volume_share_target", name, volume_target, volume_share, attempt)
          end
        end

        goals
      end.uniq { |goal| [goal["goal"], goal["provider"], goal["reason"]] }
    end

    def unmet_goal(goal, provider_name, target, share, attempt)
      {
        "goal" => goal,
        "provider" => provider_name,
        "status" => "unreachable_for_operation",
        "target_pct" => numeric(target),
        "current_attempt_share_pct" => numeric(share),
        "reason" => attempt["reason"],
        "details" => attempt["details"]
      }
    end

    def volume_target_for(provider)
      return policy.volume_target_for(provider).to_f if policy.respond_to?(:volume_target_for)

      explicit = provider["volume_share_pct"]
      explicit.nil? ? provider["traffic_percentage"].to_f : explicit.to_f
    end

    def serializable_metrics
      {
        "attempt_count_by_provider" => @attempt_metrics[:count_by_provider].to_h,
        "attempt_volume_by_provider" => @attempt_metrics[:volume_by_provider].transform_values { |value| numeric(value) },
        "total_attempts" => @attempt_metrics[:total_count],
        "total_attempt_volume" => numeric(@attempt_metrics[:total_volume]),
        "final_count_by_provider" => @metrics[:count_by_provider].to_h,
        "final_volume_by_provider" => @metrics[:volume_by_provider].transform_values { |value| numeric(value) },
        "total_final_assignments" => @metrics[:total_count],
        "total_final_volume" => numeric(@metrics[:total_volume]),
        # Знаменатель целевых долей: fallback и невыполнимые операции показаны
        # рядом, но вынесены из целевой арифметики.
        "external_count_by_provider" => @metrics[:external_count_by_provider].to_h,
        "external_volume_by_provider" => @metrics[:external_volume_by_provider].transform_values { |value| numeric(value) },
        "total_external_assignments" => @metrics[:external_count],
        "total_external_volume" => numeric(@metrics[:external_volume]),
        "fallback_assignments" => @metrics[:fallback_count],
        "fallback_volume" => numeric(@metrics[:fallback_volume]),
        "unroutable_operations" => @metrics[:unroutable_count]
      }
    end

    def external_providers
      @external_providers ||= providers.reject(&:self_provider?)
    end

    def self_provider
      providers.find(&:self_provider?)
    end

    def numeric(value)
      value == value.to_i ? value.to_i : value.round(2)
    end

    def stringify(value)
      case value
      when Hash then value.to_h { |key, item| [key.to_s, stringify(item)] }
      when Array then value.map { |item| stringify(item) }
      when Float then numeric(value)
      else value
      end
    end
  end
end
