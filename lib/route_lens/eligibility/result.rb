# frozen_string_literal: true

module RouteLens
  module Eligibility
    Result = Struct.new(:eligible, :reason, :details, :rule, keyword_init: true) do
      def eligible?
        eligible
      end

      def failed?
        !eligible?
      end

      def to_h
        return { "eligible" => true, "rule" => rule } if eligible?

        {
          "eligible" => false,
          "reason" => reason,
          "details" => details,
          "rule" => rule
        }
      end
    end

    class Evaluation
      attr_reader :results

      def initialize(results)
        @results = results.freeze
      end

      def eligible?
        failures.empty?
      end

      def failures
        @failures ||= results.select(&:failed?).freeze
      end

      def primary_failure
        failures.first
      end

      def reason
        primary_failure&.reason
      end

      def details
        primary_failure&.details
      end

      def to_h
        if eligible?
          { "eligible" => true, "failures" => [] }
        else
          {
            "eligible" => false,
            "reason" => reason,
            "details" => details,
            "failures" => failures.map(&:to_h)
          }
        end
      end
    end
  end
end
