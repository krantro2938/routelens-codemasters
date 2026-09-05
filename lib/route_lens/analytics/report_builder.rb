# frozen_string_literal: true

require_relative 'history_analyzer'
require_relative 'recommendation_engine'
require_relative 'support'

module RouteLens
  module Analytics
    # Строит обязательную структуру routing_report и операционные детали для demo.
    # Не зависит от Router, поэтому сохранённые решения можно анализировать позже.
    class ReportBuilder
      OUTCOMES = %w[approved rejected expired].freeze
      SELF_PROVIDER = 'spacepayments'
      POLICY_NONSELECTION_REASONS = %w[
        lower_policy_score
        lower_score
        lower_ranked_candidate
        not_selected_by_policy
        policy_not_selected
      ].freeze

      def initialize(providers:, operations:, decisions:, final_state: nil, history: nil, period: nil, policy: nil)
        @provider_snapshot = providers
        @providers = Support.provider_list(providers)
        @operations = Array(operations).map { |operation| Support.hash(operation) }
        @decisions = Array(decisions).map { |decision| Support.hash(decision) }
        @final_state = final_state
        @history = normalize_history(history)
        @explicit_period = period
        @policy = policy

        @operations_by_id = @operations.to_h do |operation|
          [Support.fetch(operation, 'operation_id').to_s, operation]
        end
        @providers_by_name = @providers.to_h do |provider|
          [Support.provider_name(provider).to_s, provider]
        end
        @final_providers_by_name = Support.provider_list(final_state).to_h do |provider|
          [Support.provider_name(provider).to_s, provider]
        end
      end

      def build
        distribution = count_distribution
        volumes = volume_distribution
        skips, skips_by_provider, policy_nonselections = skip_reason_metrics
        utilization = projected_utilization
        attempts = attempt_outcome_metrics
        provider_details = provider_metrics(distribution, volumes, utilization, skips_by_provider, attempts)
        unmet = unmet_goals(distribution, volumes, skips_by_provider)

        recommender = RecommendationEngine.new(
          providers: @providers,
          distribution: distribution,
          projected_daily_utilization: utilization,
          provider_metrics: provider_details,
          history: @history,
          skip_reasons_by_provider: skips_by_provider,
          policy: @policy
        )
        recommendations = recommender.generate

        {
          'period' => report_period,
          'total_operations' => @decisions.length,
          'total_amount' => Support.round(total_routed_amount),
          'policy' => policy_summary,
          'distribution' => distribution,
          'volume_distribution' => volumes,
          'outcomes' => outcome_metrics,
          'final_operation_outcomes' => outcome_metrics,
          'attempt_outcomes' => attempts,
          'latency' => latency_metrics,
          'skip_reasons' => skips,
          'skip_reasons_by_provider' => skips_by_provider,
          'policy_nonselections' => policy_nonselections,
          'retry_count' => retry_count,
          'fallback_count' => fallback_count,
          'routing_resilience' => {
            'retry_count' => retry_count,
            'operations_retried' => retried_operation_count,
            'fallback_count' => fallback_count,
            'fallback_share_pct' => Support.percent(fallback_count, @decisions.length)
          },
          # Имя поля сохранено точно по формату задания.
          'projected_daily_utilization' => utilization,
          'capacity_utilization' => utilization,
          'provider_metrics' => provider_details,
          'unmet_goals' => unmet,
          'history' => @history,
          'recommendations' => recommendations,
          'recommendation_details' => recommender.details
        }
      end
      alias call build

      private

      def normalize_history(history)
        return {} if history.nil?
        return history.analyze if history.respond_to?(:analyze)

        if history.is_a?(Array) || defined?(CSV::Table) && history.is_a?(CSV::Table)
          return HistoryAnalyzer.new(history).analyze
        end

        Support.hash(history)
      end

      def report_period
        return @explicit_period unless @explicit_period.nil?

        Support.period(@operations.map { |operation| Support.fetch(operation, 'created_at') }) ||
          Support.fetch(@provider_snapshot, 'snapshot_at')&.to_s&.slice(0, 10)
      end

      def provider_names
        (@providers_by_name.keys + @decisions.map { |decision| selected_provider(decision) })
          .reject(&:empty?).uniq
      end

      def selected_provider(decision)
        Support.fetch(decision, 'selected_provider').to_s
      end

      def decision_operation(decision)
        @operations_by_id[Support.fetch(decision, 'operation_id').to_s] || {}
      end

      def decision_amount(decision)
        Support.number(Support.fetch(decision_operation(decision), 'amount'))
      end

      def total_routed_amount
        @decisions.sum { |decision| decision_amount(decision) }
      end

      def count_distribution
        total = @decisions.length
        provider_names.to_h do |name|
          count = @decisions.count { |decision| selected_provider(decision) == name }
          target = Support.number(Support.fetch(@providers_by_name[name], 'traffic_percentage'))
          share = Support.percent(count, total)
          [name, {
            'count' => count,
            'share_pct' => share,
            'target_pct' => Support.round(target),
            'delta_pct' => Support.round(share - target)
          }]
        end
      end

      def volume_distribution
        total = total_routed_amount
        provider_names.to_h do |name|
          amount = @decisions.sum do |decision|
            selected_provider(decision) == name ? decision_amount(decision) : 0.0
          end
          provider = @providers_by_name[name]
          target, source = volume_target(provider)
          share = Support.percent(amount, total)
          [name, {
            'amount' => Support.round(amount),
            'share_pct' => share,
            'target_pct' => Support.round(target),
            'delta_pct' => Support.round(share - target),
            'target_source' => source
          }]
        end
      end

      def volume_target(provider)
        if @policy&.respond_to?(:volume_target_for)
          return [@policy.volume_target_for(provider), @policy.volume_target_source_for(provider)]
        end

        explicit = Support.fetch(provider, 'volume_share_pct')
        return [Support.number(explicit), 'volume_share_pct'] unless explicit.nil?

        [Support.number(Support.fetch(provider, 'traffic_percentage')), 'traffic_percentage_fallback']
      end

      def policy_summary
        return {} unless @policy

        {
          'name' => @policy.name,
          'preset' => @policy.respond_to?(:preset) ? @policy.preset : nil,
          'weights' => @policy.weights,
          'count_targets' => @providers.reject { |provider| Support.provider_name(provider) == SELF_PROVIDER }
                                        .to_h { |provider| [Support.provider_name(provider), Support.number(Support.fetch(provider, 'traffic_percentage'))] },
          'volume_targets' => @providers.reject { |provider| Support.provider_name(provider) == SELF_PROVIDER }
                                         .to_h { |provider| [Support.provider_name(provider), Support.round(volume_target(provider).first)] }
        }
      end

      def outcome_metrics
        total = @decisions.length
        result = OUTCOMES.to_h do |status|
          decisions = @decisions.select { |decision| outcome(decision) == status }
          [status, {
            'count' => decisions.length,
            'share_pct' => Support.percent(decisions.length, total),
            'amount' => Support.round(decisions.sum { |decision| decision_amount(decision) })
          }]
        end
        known = OUTCOMES.sum { |status| result.dig(status, 'count') }
        result['unknown'] = {
          'count' => total - known,
          'share_pct' => Support.percent(total - known, total)
        }
        result['approval_rate_pct'] = Support.percent(result.dig('approved', 'count'), total)
        result['failure_rate_pct'] = Support.percent(
          result.dig('rejected', 'count').to_i + result.dig('expired', 'count').to_i,
          total
        )
        result
      end

      def outcome(decision)
        Support.fetch(decision, 'simulated_result', Support.fetch(decision, 'result')).to_s
      end

      def actual_attempt_records
        # Финальное назначение и реальные вызовы — разные сущности: при retry
        # одна выплата создаёт несколько записей попыток.
        @actual_attempt_records ||= @decisions.flat_map do |decision|
          operation_id = Support.fetch(decision, 'operation_id').to_s
          amount = decision_amount(decision)
          actual_attempts = Array(Support.fetch(decision, 'attempts', [])).filter_map do |raw_attempt|
            attempt = Support.hash(raw_attempt)
            actual = Support.fetch(attempt, 'decision').to_s == 'selected' || !Support.fetch(attempt, 'outcome').nil?
            attempt if actual
          end
          actual_attempts.map.with_index do |attempt, index|
            attempt_outcome = Support.fetch(attempt, 'outcome').to_s
            attempt_outcome = outcome(decision) if attempt_outcome.empty? && index == actual_attempts.length - 1

            {
              'operation_id' => operation_id,
              'provider' => Support.fetch(attempt, 'provider').to_s,
              'outcome' => attempt_outcome,
              'latency_sec' => Support.fetch(attempt, 'latency_sec'),
              'amount' => amount
            }
          end
        end
      end

      def attempt_outcome_metrics
        records = actual_attempt_records
        by_provider = provider_names.to_h do |name|
          matching = records.select { |record| record['provider'] == name }
          [name, summarize_attempt_records(matching)]
        end
        failed_operations = records.select { |record| %w[rejected expired].include?(record['outcome']) }
                                   .map { |record| record['operation_id'] }.uniq
        recovered = @decisions.count do |decision|
          failed_operations.include?(Support.fetch(decision, 'operation_id').to_s) && outcome(decision) == 'approved'
        end

        summarize_attempt_records(records).merge(
          'by_provider' => by_provider,
          'operations_with_failed_attempts' => failed_operations.length,
          'recovered_operations' => recovered,
          'recovery_rate_pct' => Support.percent(recovered, failed_operations.length)
        )
      end

      def summarize_attempt_records(records)
        counts = OUTCOMES.to_h { |status| [status, records.count { |record| record['outcome'] == status }] }
        known = counts.values.sum
        latencies = records.filter_map do |record|
          value = record['latency_sec']
          Support.number(value) unless value.nil? || value == ''
        end
        {
          'total_attempts' => records.length,
          'approved' => counts['approved'],
          'rejected' => counts['rejected'],
          'expired' => counts['expired'],
          'unknown' => records.length - known,
          'approval_rate_pct' => Support.percent(counts['approved'], records.length),
          'failure_rate_pct' => Support.percent(counts['rejected'] + counts['expired'], records.length),
          'latency' => latency_summary(latencies)
        }
      end

      def latency_metrics
        all = decision_latencies(@decisions)
        by_provider = provider_names.to_h do |name|
          matching = @decisions.select { |decision| selected_provider(decision) == name }
          values = decision_latencies(matching)
          [name, latency_summary(values)]
        end
        latency_summary(all).merge('by_provider' => by_provider)
      end

      def decision_latencies(decisions)
        decisions.filter_map do |decision|
          value = Support.fetch(decision, 'latency_sec')
          Support.number(value) unless value.nil? || value == ''
        end
      end

      def latency_summary(values)
        {
          'sample_count' => values.length,
          'avg_sec' => Support.average(values),
          'p95_sec' => Support.percentile(values, 0.95),
          'max_sec' => values.empty? ? 0.0 : Support.round(values.max)
        }
      end

      def skip_reason_metrics
        # Мягкий невыбор не является техническим отказом. Разделение не даёт
        # отчёту завышать количество нарушений жёстких правил.
        global = Hash.new(0)
        per_provider = Hash.new { |hash, provider| hash[provider] = Hash.new(0) }
        policy_global = Hash.new(0)
        policy_per_provider = Hash.new { |hash, provider| hash[provider] = Hash.new(0) }
        @decisions.each do |decision|
          Array(Support.fetch(decision, 'attempts', [])).each do |raw_attempt|
            attempt = Support.hash(raw_attempt)
            next unless Support.fetch(attempt, 'decision').to_s == 'skipped'

            provider = Support.fetch(attempt, 'provider').to_s
            reason = Support.fetch(attempt, 'reason', 'unspecified').to_s
            reason = 'unspecified' if reason.empty?
            if policy_nonselection_reason?(reason)
              policy_global[reason] += 1
              policy_per_provider[provider][reason] += 1 unless provider.empty?
            else
              global[reason] += 1
              per_provider[provider][reason] += 1 unless provider.empty?
            end
          end
        end
        policy_by_provider = policy_per_provider.sort.to_h do |provider, reasons|
          [provider, sorted_counts(reasons)]
        end
        [
          sorted_counts(global),
          per_provider.sort.to_h { |provider, reasons| [provider, sorted_counts(reasons)] },
          {
            'total' => policy_global.values.sum,
            'reasons' => sorted_counts(policy_global),
            'by_provider' => policy_by_provider
          }
        ]
      end

      def policy_nonselection_reason?(reason)
        POLICY_NONSELECTION_REASONS.include?(reason)
      end

      def sorted_counts(counts)
        counts.sort_by { |key, value| [-value, key] }.to_h
      end

      def selected_attempts(decision)
        Array(Support.fetch(decision, 'attempts', [])).count do |raw_attempt|
          attempt = Support.hash(raw_attempt)
          decision_value = Support.fetch(attempt, 'decision').to_s
          decision_value == 'selected' || !Support.fetch(attempt, 'outcome').nil?
        end
      end

      def retries_for(decision)
        explicit = Support.fetch(decision, 'retry_count')
        return [Support.integer(explicit), 0].max unless explicit.nil?

        [selected_attempts(decision) - 1, 0].max
      end

      def retry_count
        @retry_count ||= @decisions.sum { |decision| retries_for(decision) }
      end

      def retried_operation_count
        @decisions.count { |decision| retries_for(decision).positive? }
      end

      def fallback_count
        @fallback_count ||= @decisions.count do |decision|
          selected_provider(decision) == SELF_PROVIDER || Support.fetch(decision, 'fallback') == true
        end
      end

      def projected_utilization
        provider_names.to_h do |name|
          snapshot = @providers_by_name[name] || {}
          state = @final_providers_by_name[name]
          limit = Support.fetch(state || snapshot, 'daily_amount_limit', Support.fetch(snapshot, 'daily_amount_limit'))
          used = final_daily_used(name, snapshot, state)
          in_progress_count = Support.integer(
            Support.fetch(state || snapshot, 'in_progress_count', Support.fetch(snapshot, 'in_progress_count'))
          )
          in_progress_amount = Support.number(
            Support.fetch(state || snapshot, 'in_progress_amount', Support.fetch(snapshot, 'in_progress_amount'))
          )
          utilization_pct = limit.nil? || Support.number(limit).zero? ? nil : Support.percent(used, limit)
          headroom = limit.nil? ? nil : [Support.number(limit) - used, 0.0].max
          [name, {
            'used' => Support.round(used),
            'limit' => limit.nil? ? nil : Support.round(limit),
            'utilization_pct' => utilization_pct,
            'headroom' => headroom.nil? ? nil : Support.round(headroom),
            'in_progress_count' => in_progress_count,
            'in_progress_amount' => Support.round(in_progress_amount)
          }]
        end
      end

      def final_daily_used(name, snapshot, state)
        unless state.nil?
          state_hash = Support.hash(state)
          if state_hash.key?('daily_approved_amount') || state_hash.key?(:daily_approved_amount)
            return Support.number(Support.fetch(state_hash, 'daily_approved_amount'))
          end
        end

        initial = Support.number(Support.fetch(snapshot, 'daily_approved_amount'))
        approved = @decisions.sum do |decision|
          selected_provider(decision) == name && outcome(decision) == 'approved' ? decision_amount(decision) : 0.0
        end
        initial + approved
      end

      def provider_metrics(distribution, volumes, utilization, skips_by_provider, attempts)
        historical = Support.hash(Support.fetch(@history, 'providers', {}))
        provider_names.to_h do |name|
          decisions = @decisions.select { |decision| selected_provider(decision) == name }
          status_counts = OUTCOMES.to_h do |status|
            [status, decisions.count { |decision| outcome(decision) == status }]
          end
          live_conversion = Support.number(Support.fetch(@providers_by_name[name], 'conversion_24h')) * 100.0
          historical_rate = Support.fetch(historical[name], 'approval_rate_pct')
          [name, {
            'operations' => decisions.length,
            'amount' => volumes.dig(name, 'amount'),
            'count_share_pct' => distribution.dig(name, 'share_pct'),
            'count_target_pct' => distribution.dig(name, 'target_pct'),
            'count_delta_pct' => distribution.dig(name, 'delta_pct'),
            'volume_share_pct' => volumes.dig(name, 'share_pct'),
            'volume_target_pct' => volumes.dig(name, 'target_pct'),
            'volume_delta_pct' => volumes.dig(name, 'delta_pct'),
            'outcomes' => status_counts,
            'approval_rate_pct' => Support.percent(status_counts['approved'], decisions.length),
            'attempts' => attempts.dig('by_provider', name, 'total_attempts') || 0,
            'attempt_outcomes' => attempts.dig('by_provider', name) || {},
            'attempt_approval_rate_pct' => attempts.dig('by_provider', name, 'approval_rate_pct') || 0.0,
            'live_conversion_24h_pct' => Support.round(live_conversion),
            'historical_approval_rate_pct' => historical_rate,
            'conversion_drift_pp' => historical_rate.nil? ? nil : Support.round(live_conversion - Support.number(historical_rate)),
            'latency' => latency_summary(decision_latencies(decisions)),
            'skip_reasons' => skips_by_provider[name] || {},
            'capacity' => utilization[name]
          }]
        end
      end

      def unmet_goals(distribution, volumes, skips_by_provider)
        explicit = @decisions.flat_map do |decision|
          Array(Support.fetch(decision, 'unmet_goals', [])).map do |goal|
            Support.hash(goal).merge('operation_id' => Support.fetch(decision, 'operation_id'))
          end
        end

        # Производная цель считается невыполненной только при недоборе минимум
        # пяти процентных пунктов; превышение цели не является ошибкой.
        derived = provider_names.filter_map do |name|
          next if name == SELF_PROVIDER

          count_delta = Support.number(distribution.dig(name, 'delta_pct'))
          volume_delta = Support.number(volumes.dig(name, 'delta_pct'))
          unmet_dimensions = []
          unmet_dimensions << 'count_share' if count_delta <= -5.0
          unmet_dimensions << 'volume_share' if volume_delta <= -5.0
          next if unmet_dimensions.empty?

          provider_skips = Support.hash(skips_by_provider[name])
          dominant = provider_skips.max_by { |reason, count| [Support.integer(count), reason] }
          {
            'provider' => name,
            'goal' => 'target_distribution',
            'unmet_dimensions' => unmet_dimensions,
            'count_delta_pct' => Support.round(count_delta),
            'volume_delta_pct' => Support.round(volume_delta),
            'reason' => dominant ? "hard_constraints:#{dominant[0]}" : 'batch_mix_or_policy_tradeoff',
            'evidence_count' => dominant ? Support.integer(dominant[1]) : 0
          }
        end

        (explicit + derived).uniq
      end
    end
  end
end
