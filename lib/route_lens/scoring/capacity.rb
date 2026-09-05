# frozen_string_literal: true

require_relative "component"

module RouteLens
  module Scoring
    class Capacity < Component
      def value(provider:, state:, operation:, metrics:)
        amount = Support.number(operation, :amount)
        capacities = []
        add_remaining(capacities, provider, state, :daily_approved_amount, :daily_amount_limit, amount)
        add_remaining(capacities, provider, state, :in_progress_count, :in_progress_count_limit, 1.0)
        add_remaining(capacities, provider, state, :in_progress_amount, :in_progress_amount_limit, amount)
        return 1.0 if capacities.empty?

        capacities.sum / capacities.length
      end

      private

      def add_remaining(values, provider, state, used_key, limit_key, increment)
        limit = Support.fetch(state, limit_key, Support.fetch(provider, limit_key, nil))
        return if limit.nil? || limit.to_f <= 0.0

        used = Support.state_value(provider, state, used_key, 0.0)
        projected = used + increment
        values << Support.clamp((limit.to_f - projected) / limit.to_f)
      end
    end
  end
end
