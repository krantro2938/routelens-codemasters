# frozen_string_literal: true

require_relative "../test_helper_eligibility"

class EligibilityEvaluatorTest < Minitest::Test
  include EligibilityTestData

  def setup
    @evaluator = RouteLens::Eligibility::Evaluator.new
  end

  def test_reports_every_failure_and_stable_primary_failure
    evaluation = @evaluator.evaluate(
      provider(status: "inactive", available_requisites: 0),
      operation(amount: 50, bank: "alfa")
    )

    refute evaluation.eligible?
    assert_equal "provider_inactive", evaluation.reason
    assert_includes evaluation.failures.map(&:reason), "amount_below_minimum"
    assert_includes evaluation.failures.map(&:reason), "bank_not_in_list"
    assert_includes evaluation.failures.map(&:reason), "no_available_requisites"
    assert_equal evaluation.reason, evaluation.to_h["reason"]
  end

  def test_filters_normal_and_fallback_pools
    external = provider(payment_system: "external")
    fallback = provider(payment_system: "spacepayments", traffic_percentage: 0, banks: [])

    assert_equal ["external"], @evaluator.eligible([external, fallback], operation).map(&:payment_system)
    assert_equal ["external", "spacepayments"],
                 @evaluator.eligible([external, fallback], operation, context: { fallback: true }).map(&:payment_system)
  end

  def test_public_queue_hard_constraints_match_reference_external_providers
    root = File.expand_path("../..", __dir__)
    providers = RouteLens::InputLoader.load_providers(File.join(root, "data/providers.json"))
    providers = providers.reject(&:self_provider?)
    operations = RouteLens::InputLoader.load_operations(File.join(root, "data/operations_queue_10.json"))
    reference = JSON.parse(File.read(File.join(root, "data/reference_decisions.json")))

    operations.each do |operation|
      actual = @evaluator.eligible(providers, operation).map(&:payment_system)
      expected = reference.fetch("eligible_providers").fetch(operation.fetch("operation_id"))
      assert_equal expected, actual, operation.fetch("operation_id")
    end
  end
end
