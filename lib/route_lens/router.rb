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
    FACTOR_LABELS = {
      "count_target_gain" => "count-share balance",
      "volume_target_gain" => "volume-share balance",
      "conversion" => "conversion",
      "priority" => "cascade priority",
      "amount_preference" => "preferred amount band",
      "capacity" => "remaining capacity",
      "turnover_obligation" => "minimum-turnover obligation",
      "load" => "current load",
      "latency" => "latency",
      "cost" => "provider cost"
    }.freeze

    attr_reader :providers, :policy

    def initialize(providers:, policy:, simulator: OutcomeSimulator.new, evaluator: Eligibility::Evaluator.new)
      @providers = providers
      @policy = policy
      @simulator = simulator
      @evaluator = evaluator
      @provider_by_name = providers.to_h { |provider| [provider.payment_system, provider] }
      @initial_states = providers.to_h { |provider| [provider.payment_system, provider.snapshot] }
      # Эти метрики описывают только финальное назначение каждой выплаты и
      # поэтому используются для приближения к целевым долям.
      @metrics = {
        count_by_provider: Hash.new(0),
        volume_by_provider: Hash.new(0.0),
        total_count: 0,
        total_volume: 0.0,
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

      append_initial_hard_exclusions(attempts, operation)

      loop do
        # После каждой неудачи список строится заново по текущему состоянию:
        # резерв предыдущей попытки уже снят, а лимиты могли измениться.
        candidates = current_external_candidates(operation, attempted_names)
        break if candidates.empty?

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
            "details" => e.message
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
          "rank" => 1,
          "score" => score.fetch(:total),
          "score_breakdown" => stringify(score.fetch(:breakdown)),
          "outcome" => outcome.fetch("result"),
          "latency_sec" => outcome.fetch("latency_sec"),
          "state_before" => state_before,
          "state_reserved" => state_reserved,
          "state_after" => provider.snapshot
        }
        attempts << attempt
        selected_attempts << attempt

        if outcome.fetch("result") == "approved"
          final_provider = provider
          final_outcome = outcome
          final_score = score
          append_lower_ranked_candidates(attempts, ranking.drop(1), attempted_names)
          break
        end
      end

      unless final_provider
        # Внутренний провайдер рассматривается только после исчерпания внешних,
        # поэтому он не может случайно выиграть обычный мягкий скоринг.
        provider, outcome, fallback_attempt = execute_fallback(operation, selected_attempts.length + 1)
        attempts << fallback_attempt
        selected_attempts << fallback_attempt
        final_provider = provider
        final_outcome = outcome
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
        "state_changes" => state_changes_for(attempts),
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
        "all_reasons" => evaluation.failures.map(&:to_h)
      }
    end

    def append_lower_ranked_candidates(attempts, ranking, attempted_names)
      ranking.each_with_index do |entry, index|
        provider = entry.fetch(:provider)
        next if attempted_names.include?(provider.payment_system)

        result = entry.fetch(:result)
        attempts << {
          "provider" => provider.payment_system,
          "decision" => "skipped",
          "reason" => "lower_policy_score",
          "details" => "score #{result.fetch(:total)} ranked below selected provider",
          "rank" => index + 2,
          "score" => result.fetch(:total),
          "score_breakdown" => stringify(result.fetch(:breakdown))
        }
      end
    end

    def execute_fallback(operation, sequence)
      provider = self_provider
      raise RoutingError, "No self-provider is configured for fallback" unless provider

      evaluation = @evaluator.evaluate(provider, operation, context: { fallback: true })
      unless evaluation.eligible?
        raise RoutingError, "Fallback provider #{provider.payment_system} is unavailable: #{evaluation.reason}"
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
        "details" => "all eligible external providers were unavailable or failed",
        "outcome" => outcome.fetch("result"),
        "latency_sec" => outcome.fetch("latency_sec"),
        "state_before" => state_before,
        "state_reserved" => state_reserved,
        "state_after" => provider.snapshot
      }

      [provider, outcome, attempt]
    rescue StateError => e
      raise RoutingError, "Could not reserve fallback provider: #{e.message}"
    end

    def settle(provider, result, reservation_id)
      case result
      when "approved" then provider.approve!(reservation_id: reservation_id)
      when "rejected" then provider.reject!(reservation_id: reservation_id)
      when "expired" then provider.expire!(reservation_id: reservation_id)
      else raise RoutingError, "Unknown outcome: #{result}"
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
    end

    def scoring_metrics
      # Компоненты долей получают единый снимок уже завершённых назначений;
      # текущая операция добавляется каждым компонентом только виртуально.
      {
        count_by_provider: @metrics[:count_by_provider],
        volume_by_provider: @metrics[:volume_by_provider],
        total_count: @metrics[:total_count],
        total_volume: @metrics[:total_volume],
        count_targets: @metrics[:count_targets],
        providers: external_providers
      }
    end

    def selection_details(score, ranking)
      runner = ranking[1]&.fetch(:result)
      return "Only provider remaining after hard constraints." unless runner

      chosen_breakdown = score.fetch(:breakdown)
      runner_breakdown = runner.fetch(:breakdown)
      advantages = chosen_breakdown.filter_map do |name, entry|
        delta = entry.fetch(:contribution) - runner_breakdown.fetch(name, {}).fetch(:contribution, 0.0)
        [name, delta] if delta > 0.01
      end.sort_by { |_name, delta| -delta }.first(2)
      drivers = advantages.map { |name, delta| "#{FACTOR_LABELS.fetch(name, name)} (+#{numeric(delta)})" }
      because = drivers.empty? ? "the combined policy score was higher" : drivers.join(" and ")
      "Selected because #{because}; score #{score.fetch(:total)} versus #{runner.fetch(:total)}."
    end

    def decision_summary(selected_attempts, final_provider)
      failures = selected_attempts.count { |attempt| %w[rejected expired].include?(attempt["outcome"]) }
      if failures.positive?
        sequence = selected_attempts.map { |attempt| "#{attempt['provider']} #{attempt['outcome']}" }.join("; ")
        "Recovered after #{failures} failed provider attempt#{failures == 1 ? '' : 's'}: #{sequence}."
      else
        details = selected_attempts.last&.fetch("details", nil)
        "#{final_provider.payment_system} completed the payout. #{details}".strip
      end
    end

    def unmet_goals_for(attempts)
      return [] unless @metrics[:total_count].positive?

      # Фиксируем только недобор цели из-за жёсткого ограничения. Превышение
      # цели не является невыполненной целью и не должно попадать в объяснение.
      attempts.filter_map do |attempt|
        next unless attempt["decision"] == "skipped"
        next if %w[lower_policy_score state_changed_during_selection].include?(attempt["reason"])

        provider = @provider_by_name[attempt["provider"]]
        next unless provider && !provider.self_provider?

        target = provider["traffic_percentage"].to_f
        actual = @metrics[:count_by_provider][provider.payment_system] * 100.0 / @metrics[:total_count]
        next unless actual + 0.01 < target

        {
          "goal" => "count_share_target",
          "provider" => provider.payment_system,
          "status" => "unreachable_for_operation",
          "target_pct" => numeric(target),
          "current_attempt_share_pct" => numeric(actual),
          "reason" => attempt["reason"],
          "details" => attempt["details"]
        }
      end.uniq { |goal| [goal["provider"], goal["reason"]] }
    end

    def state_changes_for(attempts)
      attempts.select { |attempt| attempt["decision"] == "selected" }.to_h do |attempt|
        name = attempt.fetch("provider")
        [name, {
          "before" => attempt["state_before"] || @initial_states[name],
          "after" => attempt["state_after"] || @provider_by_name.fetch(name).snapshot
        }]
      end
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
        "total_final_volume" => numeric(@metrics[:total_volume])
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
