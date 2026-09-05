# frozen_string_literal: true

require_relative "component"

module RouteLens
  module Scoring
    class Load < Component
      def value(provider:, state:, operation:, metrics:)
        utilizations = []
        add_utilization(utilizations, provider, state, :in_progress_count, :in_progress_count_limit)
        add_utilization(utilizations, provider, state, :in_progress_amount, :in_progress_amount_limit)
        return 0.0 if utilizations.empty?

        utilizations.sum / utilizations.length
      end

      private

      def add_utilization(values, provider, state, used_key, limit_key)
        limit = Support.state_value(provider, state, limit_key, 0.0)
        return unless limit.positive?

        used = Support.state_value(provider, state, used_key, 0.0)
        values << Support.clamp(used / limit)
      end
    end
  end
end
