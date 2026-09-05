# frozen_string_literal: true

require_relative "component"

module RouteLens
  module Scoring
    class Priority < Component
      def value(provider:, state:, operation:, metrics:)
        candidate_priorities = Support.candidates(metrics).map { |item| Support.number(item, :priority, 1.0) }
        current = Support.number(provider, :priority, 1.0)
        candidate_priorities << current
        minimum, maximum = candidate_priorities.minmax
        return 1.0 if maximum == minimum

        1.0 - ((current - minimum) / (maximum - minimum))
      end
    end
  end
end
