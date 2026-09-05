# frozen_string_literal: true

require_relative "rules"

module RouteLens
  module Eligibility
    class Evaluator
      DEFAULT_RULES = [
        StatusRule,
        SelfProviderRule,
        TrafficEnabledRule,
        AmountRule,
        DailyAmountRule,
        InProgressCountRule,
        InProgressAmountRule,
        BankRule,
        MarginRule,
        RequisitesRule,
        RateLimitRule
      ].freeze

      attr_reader :rules

      def initialize(rules: DEFAULT_RULES.map(&:new))
        @rules = rules.freeze
      end

      # Every rule is evaluated so the decision receipt can expose all causes.
      # The first failure in the configured rule order is the stable primary cause.
      def evaluate(provider, operation, context: {})
        Evaluation.new(rules.map { |rule| rule.evaluate(provider, operation, context: context) })
      end

      def eligible?(provider, operation, context: {})
        evaluate(provider, operation, context: context).eligible?
      end

      def evaluate_all(providers, operation, context: {})
        providers.to_h { |provider| [provider_name(provider), evaluate(provider, operation, context: context)] }
      end

      def eligible(providers, operation, context: {})
        providers.select { |provider| eligible?(provider, operation, context: context) }
      end

      private

      def provider_name(provider)
        provider.respond_to?(:payment_system) ? provider.payment_system : provider["payment_system"]
      end
    end
  end
end
