# frozen_string_literal: true

require_relative "analytics/report_builder"
require_relative "outcome_simulator"
require_relative "provider_state"
require_relative "router"
require_relative "scoring/policy"

module RouteLens
  # Проигрывает одну очередь с несколькими пресетами и первой безопасной
  # рекомендацией отчёта. approve_all убирает влияние смоделированных отказов,
  # поэтому различия объясняются только политикой выбора.
  class PolicyComparison
    DEFAULT_PRESETS = %w[conversion_first cascade capacity_first].freeze

    def initialize(provider_snapshot:, operations:, policy_config:, history: nil, presets: DEFAULT_PRESETS)
      @snapshot_metadata = provider_snapshot.reject { |key, _value| key == "providers" }
      @provider_attributes = provider_snapshot.fetch("providers").map do |provider|
        provider.respond_to?(:snapshot) ? provider.snapshot : deep_copy(provider)
      end
      @operations = deep_copy(operations)
      @policy_config = policy_config
      @history = history
      @presets = presets
    end

    def build
      balanced = run_scenario("balanced", preset: nil)
      scenarios = [balanced]
      @presets.each { |preset| scenarios << run_scenario(preset, preset: preset) }
      scenarios.each { |scenario| add_changed_operations!(scenario, balanced) }

      recommendation = capacity_recommendation(balanced.fetch("report"))
      replay = recommendation && replay_recommendation(recommendation, balanced)

      {
        "simulation" => "approve_all",
        "purpose" => "Отделить влияние политики выбора от смоделированных исходов провайдеров",
        "scenarios" => scenarios.map { |scenario| scenario.reject { |key, _value| key == "report" } },
        "recommendation_replay" => replay
      }
    end

    private

    def run_scenario(label, preset:, traffic_targets: nil)
      policy = Scoring::Policy.load(@policy_config, preset: preset)
      providers = fresh_providers(traffic_targets)
      initial = @snapshot_metadata.merge("providers" => providers.map(&:snapshot))
      result = Router.new(
        providers: providers,
        policy: policy,
        simulator: OutcomeSimulator.new(mode: "approve_all")
      ).route(@operations)
      report = Analytics::ReportBuilder.new(
        providers: initial,
        operations: @operations,
        decisions: result.decisions,
        final_state: { "providers" => result.provider_states.values },
        history: @history,
        policy: policy
      ).build

      {
        "name" => label,
        "policy" => policy.name,
        "weights" => policy.weights,
        "traffic_targets" => traffic_targets || report.dig("policy", "count_targets"),
        "distribution" => compact_distribution(report.fetch("distribution")),
        "volume_distribution" => compact_distribution(report.fetch("volume_distribution")),
        "count_target_error_pp" => target_error(report.fetch("distribution")),
        "volume_target_error_pp" => target_error(report.fetch("volume_distribution")),
        "approval_rate_pct" => report.dig("outcomes", "approval_rate_pct"),
        "fallback_count" => report.fetch("fallback_count"),
        # Отчёт хранит поле под именем из задания; здесь оно остаётся
        # capacity_utilization, потому что на это имя смотрит Observatory.
        "capacity_utilization" => report.fetch("projected_daily_utilization").to_h do |provider, metrics|
          [provider, { "utilization_pct" => metrics["utilization_pct"], "headroom" => metrics["headroom"] }]
        end,
        "selections" => result.decisions.to_h { |decision| [decision.fetch("operation_id"), decision.fetch("selected_provider")] },
        "report" => report
      }
    end

    def replay_recommendation(recommendation, balanced)
      action = recommendation.fetch("action")
      targets = action.fetch("target_vector_after")
      constrained_provider = recommendation.fetch("provider")
      replay = run_scenario("recommended_targets", preset: nil, traffic_targets: targets)
      add_changed_operations!(replay, balanced)
      {
        "recommendation" => recommendation,
        "before" => balanced.reject { |key, _value| key == "report" || key == "selections" || key == "weights" },
        "after" => replay.reject { |key, _value| key == "report" || key == "selections" || key == "weights" },
        "tradeoffs" => {
          "count_target_error_change_pp" => (replay["count_target_error_pp"] - balanced["count_target_error_pp"]).round(2),
          "volume_target_error_change_pp" => (replay["volume_target_error_pp"] - balanced["volume_target_error_pp"]).round(2),
          "constrained_provider" => constrained_provider,
          "capacity_utilization_change_pp" => (
            replay.dig("capacity_utilization", constrained_provider, "utilization_pct").to_f -
            balanced.dig("capacity_utilization", constrained_provider, "utilization_pct").to_f
          ).round(2)
        }
      }
    end

    def capacity_recommendation(report)
      Array(report["recommendation_details"]).find do |item|
        item["type"] == "capacity_pressure" && item.dig("action", "target_vector_after")
      end
    end

    def fresh_providers(traffic_targets)
      @provider_attributes.map do |attributes|
        copy = deep_copy(attributes)
        name = copy.fetch("payment_system")
        copy["traffic_percentage"] = traffic_targets[name] if traffic_targets&.key?(name)
        ProviderState.new(copy)
      end
    end

    def compact_distribution(distribution)
      distribution.to_h do |provider, metrics|
        [provider, {
          "share_pct" => metrics["share_pct"],
          "target_pct" => metrics["target_pct"],
          "delta_pct" => metrics["delta_pct"]
        }]
      end
    end

    def target_error(distribution)
      distribution.reject { |provider, _metrics| provider == ProviderState::SELF_PROVIDER }
                  .values.sum { |metrics| metrics.fetch("delta_pct").abs }.round(2)
    end

    def add_changed_operations!(scenario, baseline)
      baseline_selections = baseline.fetch("selections")
      scenario["changed_operations_vs_balanced"] = scenario.fetch("selections").filter_map do |operation_id, provider|
        before = baseline_selections.fetch(operation_id)
        { "operation_id" => operation_id, "from" => before, "to" => provider } unless before == provider
      end
    end

    def deep_copy(value)
      Marshal.load(Marshal.dump(value))
    end
  end
end
