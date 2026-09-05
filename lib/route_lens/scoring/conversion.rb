# frozen_string_literal: true

require_relative "component"

module RouteLens
  module Scoring
    # Передаёт текущую conversion_24h как уже нормализованный фактор качества.
    class Conversion < Component
      def value(provider:, state:, operation:, metrics:)
        Support.number(provider, :conversion_24h)
      end
    end
  end
end
