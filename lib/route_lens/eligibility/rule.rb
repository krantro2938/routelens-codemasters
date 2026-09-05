# frozen_string_literal: true

require_relative "result"

module RouteLens
  module Eligibility
    class Rule
      def evaluate(_provider, _operation, context: {})
        raise NotImplementedError, "#{self.class} must implement #evaluate"
      end

      private

      def pass
        Result.new(eligible: true, rule: rule_name)
      end

      def fail(reason, details)
        Result.new(eligible: false, reason: reason, details: details, rule: rule_name)
      end

      def rule_name
        self.class.name.split("::").last.sub(/Rule$/, "").gsub(/([a-z])([A-Z])/, '\\1_\\2').downcase
      end

      def provider_value(provider, key)
        provider[key.to_s]
      end

      def operation_value(operation, key)
        operation[key.to_s] || operation[key.to_sym]
      end

      def provider_name(provider)
        provider.respond_to?(:payment_system) ? provider.payment_system : provider_value(provider, "payment_system")
      end

      def number(value, default: 0.0)
        value.nil? ? default : Float(value)
      end

      def display_number(value)
        numeric = Float(value)
        numeric == numeric.to_i ? numeric.to_i : numeric
      end
    end
  end
end
