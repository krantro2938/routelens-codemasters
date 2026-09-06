# frozen_string_literal: true

require_relative "component"

module RouteLens
  module Scoring
    # Преобразует позицию каскада относительно текущих кандидатов: меньший
    # числовой priority получает большее нормализованное значение.
    class Priority < Component
      def value(provider:, state:, operation:, metrics:)
        candidate_priorities = Support.candidates(metrics).map { |item| Support.number(item, :priority, 1.0) }
        current = Support.number(provider, :priority, 1.0)
        position = Support.relative_position(current, candidate_priorities)
        # Единственный кандидат каскада — вершина каскада по определению.
        return 1.0 if position.nil?

        1.0 - position
      end
    end
  end
end
