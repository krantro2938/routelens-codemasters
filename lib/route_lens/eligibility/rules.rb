# frozen_string_literal: true

require "time"
require_relative "rule"
require_relative "../provider_state"

module RouteLens
  module Eligibility
    class StatusRule < Rule
      def evaluate(provider, _operation, context: {})
        status = provider_value(provider, "status")
        return pass if status == "active"

        fail("provider_inactive", "статус #{status.inspect} не равен active")
      end
    end

    class SelfProviderRule < Rule
      def evaluate(provider, _operation, context: {})
        self_provider = if provider.respond_to?(:self_provider?)
                          provider.self_provider?
                        else
                          provider_name(provider) == ProviderState::SELF_PROVIDER ||
                            provider_value(provider, "self_provider") == true
                        end
        return pass unless self_provider
        return pass if context[:fallback] || context[:include_self_provider]

        fail("self_provider_reserved_for_fallback", "#{provider_name(provider)} доступен только как fallback")
      end
    end

    # По входному контракту нулевая доля отключает обычный внешний маршрут;
    # положительная доля остаётся мягкой целью и здесь не ограничивается.
    class TrafficEnabledRule < Rule
      def evaluate(provider, _operation, context: {})
        target = provider_value(provider, "traffic_percentage")
        return pass if target.nil? || number(target).positive?
        return pass if provider_name(provider) == ProviderState::SELF_PROVIDER

        fail("traffic_disabled", "traffic_percentage равен 0")
      end
    end

    class AmountRule < Rule
      def evaluate(provider, operation, context: {})
        amount = number(operation_value(operation, "amount"))
        minimum = provider_value(provider, "limit_amount_min")
        maximum = provider_value(provider, "limit_amount_max")

        if minimum && amount < number(minimum)
          return fail(
            "amount_below_minimum",
            "#{display_number(amount)} < limit_amount_min #{display_number(minimum)}"
          )
        end
        if maximum && amount > number(maximum)
          return fail(
            "amount_exceeds_limit",
            "#{display_number(amount)} > limit_amount_max #{display_number(maximum)}"
          )
        end

        pass
      end
    end

    class DailyAmountRule < Rule
      def evaluate(provider, operation, context: {})
        limit = provider_value(provider, "daily_amount_limit")
        return pass if limit.nil?

        current = number(provider_value(provider, "daily_approved_amount"))
        amount = number(operation_value(operation, "amount"))
        prospective = current + amount
        return pass if prospective <= number(limit)

        fail(
          "daily_amount_limit_exceeded",
          "daily_approved_amount #{display_number(current)} + amount #{display_number(amount)} " \
          "> daily_amount_limit #{display_number(limit)}"
        )
      end
    end

    class InProgressCountRule < Rule
      def evaluate(provider, _operation, context: {})
        limit = provider_value(provider, "in_progress_count_limit")
        return pass if limit.nil?

        current = number(provider_value(provider, "in_progress_count")).to_i
        return pass if current + 1 <= number(limit)

        fail(
          "in_progress_count_limit_exceeded",
          "in_progress_count #{current} + 1 > in_progress_count_limit #{display_number(limit)}"
        )
      end
    end

    class InProgressAmountRule < Rule
      def evaluate(provider, operation, context: {})
        limit = provider_value(provider, "in_progress_amount_limit")
        return pass if limit.nil?

        current = number(provider_value(provider, "in_progress_amount"))
        amount = number(operation_value(operation, "amount"))
        prospective = current + amount
        return pass if prospective <= number(limit)

        fail(
          "in_progress_amount_limit_exceeded",
          "in_progress_amount #{display_number(current)} + amount #{display_number(amount)} " \
          "> in_progress_amount_limit #{display_number(limit)}"
        )
      end
    end

    class BankRule < Rule
      def evaluate(provider, operation, context: {})
        banks = Array(provider_value(provider, "banks")).map { |bank| normalize(bank) }
        return pass if banks.empty?

        bank = normalize(operation_value(operation, "bank"))
        excluded = provider_value(provider, "exclude_banks") == true
        if excluded && banks.include?(bank)
          fail("bank_excluded", "банк #{bank} входит в список исключённых банков провайдера")
        elsif !excluded && !banks.include?(bank)
          fail("bank_not_in_list", "банк #{bank} отсутствует в списке поддерживаемых банков провайдера")
        else
          pass
        end
      end

      private

      def normalize(bank)
        bank.to_s.strip.downcase
      end
    end

    class MarginRule < Rule
      def evaluate(provider, _operation, context: {})
        provider_margin = number(provider_value(provider, "provider_margin_pct"))
        merchant_margin = number(provider_value(provider, "merchant_margin_pct"))
        negative_allowed = provider_value(provider, "allow_negative_agreement") == true
        return pass if provider_margin <= merchant_margin || negative_allowed

        fail(
          "negative_margin_not_allowed",
          "provider_margin_pct #{display_number(provider_margin)} > " \
          "merchant_margin_pct #{display_number(merchant_margin)}"
        )
      end
    end

    class RequisitesRule < Rule
      def evaluate(provider, _operation, context: {})
        available = number(provider_value(provider, "available_requisites")).to_i
        return pass if available.positive?

        fail("no_available_requisites", "available_requisites равен #{available}")
      end
    end

    class RateLimitRule < Rule
      def evaluate(provider, operation, context: {})
        limit = provider_value(provider, "requests_per_minute_limit")
        return pass if limit.nil?

        current = request_count(provider, operation, context)
        return pass if current + 1 <= number(limit)

        fail(
          "rate_limit_exceeded",
          "запросов за текущую минуту #{current} + 1 > requests_per_minute_limit #{display_number(limit)}"
        )
      end

      private

      def request_count(provider, operation, context)
        return number(context[:requests_per_minute]) if context.key?(:requests_per_minute)

        if provider.respond_to?(:requests_per_minute)
          at = context[:at] || operation_value(operation, "created_at") || Time.now
          provider.requests_per_minute(at: at)
        else
          number(
            provider_value(provider, "requests_last_minute") ||
            provider_value(provider, "current_requests_per_minute")
          )
        end
      end
    end
  end
end
