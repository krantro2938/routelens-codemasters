# frozen_string_literal: true

require_relative 'support'

module RouteLens
  module Analytics
    # Turns report measurements into recommendations that name both the evidence
    # and the concrete parameter or rule to change.
    class RecommendationEngine
      CAPACITY_WARNING_PCT = 90.0
      CRITICAL_CAPACITY_PCT = 95.0
      CONVERSION_DRIFT_PCT = 10.0
      TARGET_DEVIATION_PCT = 10.0
      MINIMUM_HISTORY_SAMPLE = 5

      attr_reader :details

      def initialize(providers:, distribution:, projected_daily_utilization:, provider_metrics:,
                     history: nil, skip_reasons_by_provider: nil, policy: nil)
        @providers = Support.provider_list(providers)
        @distribution = Support.hash(distribution)
        @utilization = Support.hash(projected_daily_utilization)
        @provider_metrics = Support.hash(provider_metrics)
        @history = Support.hash(history)
        @skip_reasons_by_provider = Support.hash(skip_reasons_by_provider)
        @policy = policy
        @details = []
      end

      def generate
        @details = []
        add_capacity_recommendations
        add_conversion_drift_recommendations
        add_distribution_recommendations
        @details.map { |item| item['message'] }
      end
      alias call generate

      private

      def add_capacity_recommendations
        @providers.each do |provider|
          name = Support.provider_name(provider).to_s
          metrics = Support.hash(@utilization[name])
          limit = Support.fetch(metrics, 'limit')
          next if name.empty? || limit.nil? || Support.number(limit).zero?

          utilization_pct = Support.number(Support.fetch(metrics, 'utilization_pct'))
          next if utilization_pct < CAPACITY_WARNING_PCT

          current_target = Support.number(Support.fetch(provider, 'traffic_percentage'))
          suggested_target = if utilization_pct >= CRITICAL_CAPACITY_PCT
                               [current_target, 10.0].min
                             else
                               (current_target / 2.0).round
                             end
          headroom = Support.number(Support.fetch(metrics, 'headroom'))
          severity = utilization_pct >= CRITICAL_CAPACITY_PCT ? 'critical' : 'warning'
          before_vector = traffic_target_vector
          after_vector = rebalance_target(before_vector, constrained_provider: name, proposed: suggested_target)
          message = format(
            '%<provider>s daily limit is %<utilization>.1f%% utilized (%<used>.0f/%<limit>.0f RUB; %<headroom>.0f RUB headroom). ' \
            'Temporarily change traffic_percentage from %<current>.1f%% to %<suggested>.1f%% until the daily reset.',
            provider: name,
            utilization: utilization_pct,
            used: Support.number(Support.fetch(metrics, 'used')),
            limit: Support.number(limit),
            headroom: headroom,
            current: current_target,
            suggested: suggested_target
          )
          add_detail(
            type: 'capacity_pressure', severity: severity, provider: name,
            evidence: {
              'utilization_pct' => Support.round(utilization_pct),
              'used' => Support.round(Support.fetch(metrics, 'used')),
              'limit' => Support.round(limit),
              'headroom' => Support.round(headroom)
            },
            action: {
              'parameter' => 'traffic_percentage',
              'current' => Support.round(current_target),
              'proposed' => Support.round(suggested_target),
              'target_vector_before' => before_vector,
              'target_vector_after' => after_vector,
              'duration' => 'until_daily_limit_reset'
            },
            expected_impact: 'Reduce the chance of hard-limit exclusions while preserving limited capacity for eligible payouts.',
            message: message
          )
        end
      end

      def add_conversion_drift_recommendations
        historical_providers = Support.hash(Support.fetch(@history, 'providers', {}))
        @providers.each do |provider|
          name = Support.provider_name(provider).to_s
          historical = Support.hash(historical_providers[name])
          sample = Support.integer(Support.fetch(historical, 'operations'))
          next if name.empty? || sample < MINIMUM_HISTORY_SAMPLE

          live_pct = Support.number(Support.fetch(provider, 'conversion_24h')) * 100.0
          historical_pct = Support.number(Support.fetch(historical, 'approval_rate_pct'))
          drift = live_pct - historical_pct
          next if drift.abs < CONVERSION_DRIFT_PCT

          current_weight = policy_weight('conversion')
          proposed_weight = Support.round(current_weight / 2.0)

          message = format(
            '%<provider>s conversion_24h is %<live>.1f%% versus %<historical>.1f%% historical approval ' \
            '(%<drift>+.1f pp, n=%<sample>d). Temporarily reduce policy.weights.conversion from %<current>.2f to %<proposed>.2f until the metric windows are reconciled.',
            provider: name, live: live_pct, historical: historical_pct, drift: drift, sample: sample,
            current: current_weight, proposed: proposed_weight
          )
          add_detail(
            type: 'conversion_drift', severity: 'warning', provider: name,
            evidence: {
              'conversion_24h_pct' => Support.round(live_pct),
              'historical_approval_rate_pct' => Support.round(historical_pct),
              'difference_pp' => Support.round(drift),
              'historical_operations' => sample
            },
            action: {
              'parameter' => 'policy.weights.conversion',
              'current' => Support.round(current_weight),
              'proposed' => proposed_weight,
              'until' => 'live_and_historical_metric_windows_are_reconciled'
            },
            expected_impact: 'Prevent a mismatched measurement window from dominating provider selection.',
            message: message
          )
        end
      end

      def add_distribution_recommendations
        @providers.each do |provider|
          name = Support.provider_name(provider).to_s
          next if name.empty? || name == 'spacepayments'

          distribution = Support.hash(@distribution[name])
          delta = Support.number(Support.fetch(distribution, 'delta_pct'))
          next if delta.abs < TARGET_DEVIATION_PCT

          current_target = Support.number(Support.fetch(distribution, 'target_pct'))
          actual = Support.number(Support.fetch(distribution, 'share_pct'))
          skip_count = Support.hash(@skip_reasons_by_provider[name]).values.sum { |count| Support.integer(count) }
          if delta.negative? && skip_count.positive?
            message = format(
              '%<provider>s count share is %<actual>.1f%% against a %<target>.1f%% target (%<delta>+.1f pp) and it was hard-excluded %<skips>d times. ' \
              'Keep traffic_percentage at %<target>.1f%%; review the dominant eligibility rule rather than forcing non-compliant traffic.',
              provider: name, actual: actual, target: current_target, delta: delta, skips: skip_count
            )
            action = {
              'parameter' => 'traffic_percentage', 'current' => Support.round(current_target),
              'proposed' => Support.round(current_target), 'review' => 'dominant_hard_constraint'
            }
          else
            message = format(
              '%<provider>s count share is %<actual>.1f%% against a %<target>.1f%% target (%<delta>+.1f pp). ' \
              'Keep traffic_percentage at %<target>.1f%% and inspect the eligible-provider mix before changing the business target.',
              provider: name, actual: actual, target: current_target, delta: delta
            )
            action = {
              'parameter' => 'traffic_percentage', 'current' => Support.round(current_target),
              'proposed' => Support.round(current_target), 'review' => 'eligible_provider_mix_and_policy_contributions'
            }
          end
          add_detail(
            type: 'count_share_deviation', severity: 'advisory', provider: name,
            evidence: {
              'actual_share_pct' => Support.round(actual), 'target_pct' => Support.round(current_target),
              'delta_pct' => Support.round(delta), 'hard_exclusion_count' => skip_count
            },
            action: action,
            expected_impact: 'Move observed count share toward a feasible target without bypassing hard constraints.',
            message: message
          )
        end
      end

      def add_detail(type:, severity:, provider:, evidence:, action:, expected_impact:, message:)
        @details << {
          'type' => type,
          'severity' => severity,
          'provider' => provider,
          'evidence' => evidence,
          'action' => action,
          'expected_impact' => expected_impact,
          'message' => message
        }
      end

      def policy_weight(name)
        return 0.0 unless @policy&.respond_to?(:weights)

        Support.number(Support.fetch(@policy.weights, name))
      end

      def traffic_target_vector
        external = @providers.reject { |provider| Support.provider_name(provider).to_s == 'spacepayments' }
        vector = external.to_h do |provider|
          [Support.provider_name(provider).to_s, Support.number(Support.fetch(provider, 'traffic_percentage'))]
        end
        normalize_vector(vector)
      end

      def normalize_vector(vector)
        total = vector.values.sum
        return vector.transform_values { 0.0 } unless total.positive?

        normalized = vector.transform_values { |value| Support.round(value * 100.0 / total) }
        correction = Support.round(100.0 - normalized.values.sum)
        first = normalized.keys.first
        normalized[first] = Support.round(normalized[first] + correction) if first
        normalized
      end

      def rebalance_target(vector, constrained_provider:, proposed:)
        result = vector.dup
        current = Support.number(result[constrained_provider])
        result[constrained_provider] = [Support.number(proposed), current].min
        released = current - result[constrained_provider]
        receivers = result.keys.reject { |name| name == constrained_provider }
        receiver = receivers.min_by do |name|
          utilization = Support.fetch(Support.hash(@utilization[name]), 'utilization_pct')
          utilization.nil? ? -1.0 : Support.number(utilization)
        end
        result[receiver] = Support.round(result.fetch(receiver, 0.0) + released) if receiver
        normalize_vector(result)
      end
    end
  end
end
