# frozen_string_literal: true

require_relative "support"

module RouteLens
  module Scoring
    class Component
      attr_reader :config

      def initialize(config = {})
        @config = config || {}
      end

      def call(provider:, state: nil, operation:, metrics: {})
        Support.clamp(value(provider: provider, state: state, operation: operation, metrics: metrics), -1.0, 1.0)
      end
    end
  end
end
