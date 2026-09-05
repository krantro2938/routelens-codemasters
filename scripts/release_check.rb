#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"

root = File.expand_path("..", __dir__)
$LOAD_PATH.unshift File.join(root, "lib")
require "route_lens"

options = {
  providers: File.join(root, "data/providers.json"),
  queue: "operations_queue_test.json",
  decisions: "routing_decisions_test.json",
  report: "routing_report_test.json"
}

OptionParser.new do |parser|
  parser.banner = "Usage: ruby scripts/release_check.rb [options]"
  parser.on("--providers PATH", "Provider snapshot used for semantic checks") { |value| options[:providers] = value }
  parser.on("--queue PATH", "Input operations queue") { |value| options[:queue] = value }
  parser.on("--decisions PATH", "Routing decisions output") { |value| options[:decisions] = value }
  parser.on("--report PATH", "Routing report output") { |value| options[:report] = value }
end.parse!

def fail_check(message, errors)
  errors << message
  warn "FAIL: #{message}"
end

def load_json(path, errors)
  unless File.file?(path)
    fail_check("Missing file: #{path}", errors)
    return nil
  end

  JSON.parse(File.read(path))
rescue JSON::ParserError => e
  fail_check("Invalid JSON in #{path}: #{e.message}", errors)
  nil
end

def numeric(value)
  Float(value)
rescue ArgumentError, TypeError
  nil
end

def close_enough?(left, right, tolerance = 0.01)
  left_value = numeric(left)
  right_value = numeric(right)
  !left_value.nil? && !right_value.nil? && (left_value - right_value).abs <= tolerance
end

def validate_state_lifecycle(operation_id, attempt, operation, errors)
  before = attempt["state_before"]
  reserved = attempt["state_reserved"]
  after = attempt["state_after"]
  unless before.is_a?(Hash) && reserved.is_a?(Hash) && after.is_a?(Hash)
    fail_check("#{operation_id}: selected attempt is missing reservation lifecycle state", errors)
    return
  end

  amount = numeric(operation["amount"])
  return fail_check("#{operation_id}: operation amount is not numeric", errors) if amount.nil?

  expected_reserved = {
    "in_progress_count" => before["in_progress_count"].to_i + 1,
    "in_progress_amount" => before["in_progress_amount"].to_f + amount,
    "daily_approved_amount" => before["daily_approved_amount"].to_f
  }
  expected_reserved["available_requisites"] = before["available_requisites"].to_i - 1 if before.key?("available_requisites")
  expected_reserved.each do |field, expected|
    unless close_enough?(reserved[field], expected)
      fail_check("#{operation_id}: reserved #{field} does not match the expected transition", errors)
    end
  end

  expected_after = {
    "in_progress_count" => before["in_progress_count"].to_i,
    "in_progress_amount" => before["in_progress_amount"].to_f,
    "daily_approved_amount" => before["daily_approved_amount"].to_f +
      (attempt["outcome"] == "approved" ? amount : 0.0)
  }
  expected_after["available_requisites"] = before["available_requisites"].to_i if before.key?("available_requisites")
  expected_after.each do |field, expected|
    unless close_enough?(after[field], expected)
      fail_check("#{operation_id}: settled #{field} does not match the expected transition", errors)
    end
  end
end

errors = []
queue = load_json(options[:queue], errors)
decisions = load_json(options[:decisions], errors)
report = load_json(options[:report], errors)
provider_document = load_json(options[:providers], errors)

if queue && !queue.is_a?(Array)
  fail_check("Queue must be a JSON array", errors)
end
if decisions && !decisions.is_a?(Array)
  fail_check("Decisions must be a JSON array", errors)
end
if report && !report.is_a?(Hash)
  fail_check("Report must be a JSON object", errors)
end
if provider_document && !(provider_document.is_a?(Hash) && provider_document["providers"].is_a?(Array))
  fail_check("Provider snapshot must contain a providers array", errors)
end

if queue.is_a?(Array) && decisions.is_a?(Array)
  operations_by_id = queue.to_h { |operation| [operation["operation_id"], operation] }
  providers_by_name = if provider_document.is_a?(Hash) && provider_document["providers"].is_a?(Array)
                        provider_document["providers"].to_h { |provider| [provider["payment_system"], provider] }
                      else
                        {}
                      end
  evaluator = RouteLens::Eligibility::Evaluator.new
  queue_ids = queue.map { |item| item["operation_id"] }
  decision_ids = decisions.map { |item| item["operation_id"] }

  fail_check("Queue contains duplicate operation IDs", errors) unless queue_ids.uniq.size == queue_ids.size
  fail_check("Decisions contain duplicate operation IDs", errors) unless decision_ids.uniq.size == decision_ids.size

  missing = queue_ids - decision_ids
  extra = decision_ids - queue_ids
  fail_check("Missing decisions: #{missing.join(', ')}", errors) unless missing.empty?
  fail_check("Unexpected decisions: #{extra.join(', ')}", errors) unless extra.empty?

  decisions.each do |decision|
    unless decision.is_a?(Hash)
      fail_check("Each decision must be an object", errors)
      next
    end

    id = decision["operation_id"] || "<unknown>"
    %w[operation_id selected_provider attempts simulated_result].each do |field|
      fail_check("#{id}: missing #{field}", errors) unless decision.key?(field)
    end
    unless decision["attempts"].is_a?(Array) && !decision["attempts"].empty?
      fail_check("#{id}: attempts must be a non-empty array", errors)
      next
    end

    unless %w[approved rejected expired].include?(decision["simulated_result"])
      fail_check("#{id}: simulated_result must be approved, rejected, or expired", errors)
    end

    decision["attempts"].each_with_index do |attempt, index|
      unless attempt.is_a?(Hash)
        fail_check("#{id}: attempts[#{index}] must be an object", errors)
        next
      end
      %w[provider decision reason].each do |field|
        fail_check("#{id}: attempts[#{index}] missing #{field}", errors) unless attempt.key?(field)
      end
      unless %w[selected skipped].include?(attempt["decision"])
        fail_check("#{id}: attempts[#{index}] has invalid decision", errors)
      end
      if attempt.key?("outcome") && !%w[approved rejected expired].include?(attempt["outcome"])
        fail_check("#{id}: attempts[#{index}] has invalid outcome", errors)
      end
    end


    actual_attempts = decision["attempts"].select { |attempt| attempt.is_a?(Hash) && attempt["decision"] == "selected" }
    if actual_attempts.empty?
      fail_check("#{id}: no selected provider attempt", errors)
    else
      final_attempt = actual_attempts.last
      unless final_attempt["provider"] == decision["selected_provider"]
        fail_check("#{id}: selected_provider does not match the final selected attempt", errors)
      end
      if final_attempt.key?("outcome") && final_attempt["outcome"] != decision["simulated_result"]
        fail_check("#{id}: simulated_result does not match the final attempt outcome", errors)
      end
      failed_before_final = actual_attempts[0...-1]
      unless failed_before_final.all? { |attempt| %w[rejected expired].include?(attempt["outcome"]) }
        fail_check("#{id}: every attempt before the final provider must be rejected or expired", errors)
      end

      operation = operations_by_id[id]
      if operation
        actual_attempts.each_with_index do |attempt, attempt_index|
          provider_name = attempt["provider"]
          provider_attributes = attempt["state_before"] || providers_by_name[provider_name]
          unless provider_attributes.is_a?(Hash)
            fail_check("#{id}: unknown provider #{provider_name}", errors)
            next
          end

          provider = RouteLens::ProviderState.new(provider_attributes)
          fallback = provider.self_provider?
          evaluation = evaluator.evaluate(provider, operation, context: { fallback: fallback })
          unless evaluation.eligible?
            fail_check("#{id}: selected attempt #{attempt_index + 1} violates #{evaluation.reason}", errors)
          end
          validate_state_lifecycle(id, attempt, operation, errors)
        rescue ArgumentError, RouteLens::StateError => e
          fail_check("#{id}: invalid selected-attempt state: #{e.message}", errors)
        end
      end

      expected_sequence = actual_attempts.map { |attempt| attempt["provider"] }
      if decision.key?("routing_sequence") && decision["routing_sequence"] != expected_sequence
        fail_check("#{id}: routing_sequence does not match selected attempts", errors)
      end
      if decision.key?("latency_sec") && actual_attempts.all? { |attempt| attempt.key?("latency_sec") }
        expected_latency = actual_attempts.sum { |attempt| attempt["latency_sec"].to_i }
        fail_check("#{id}: latency_sec does not equal attempt latency", errors) unless decision["latency_sec"].to_i == expected_latency
      end
    end
  end

  if report.is_a?(Hash)
    fail_check("Report total_operations does not match queue", errors) unless report["total_operations"].to_i == queue.size
    fail_check("Report is missing distribution", errors) unless report["distribution"].is_a?(Hash)
    unless report["recommendations"].is_a?(Array) && !report["recommendations"].empty?
      fail_check("Report recommendations must be a non-empty array", errors)
    end

    queue_amounts = queue.to_h { |operation| [operation["operation_id"], numeric(operation["amount"]) || 0.0] }
    expected_amount = decisions.sum { |decision| queue_amounts.fetch(decision["operation_id"], 0.0) }
    unless close_enough?(report["total_amount"], expected_amount)
      fail_check("Report total_amount does not reconcile with the queue", errors)
    end

    if report["distribution"].is_a?(Hash)
      expected_counts = decisions.group_by { |decision| decision["selected_provider"] }.transform_values(&:length)
      reported_count_sum = report["distribution"].values.sum { |metrics| metrics.is_a?(Hash) ? metrics["count"].to_i : 0 }
      fail_check("Report distribution counts do not sum to total_operations", errors) unless reported_count_sum == decisions.length
      expected_counts.each do |provider, count|
        unless report.dig("distribution", provider, "count").to_i == count
          fail_check("Report distribution count for #{provider} does not match decisions", errors)
        end
      end
    end

    if report["volume_distribution"].is_a?(Hash)
      expected_volumes = Hash.new(0.0)
      decisions.each do |decision|
        expected_volumes[decision["selected_provider"]] += queue_amounts.fetch(decision["operation_id"], 0.0)
      end
      expected_volumes.each do |provider, amount|
        unless close_enough?(report.dig("volume_distribution", provider, "amount"), amount)
          fail_check("Report volume for #{provider} does not match decisions", errors)
        end
      end
    end

    expected_retries = decisions.sum do |decision|
      [decision.fetch("attempts", []).count { |attempt| attempt.is_a?(Hash) && attempt["decision"] == "selected" } - 1, 0].max
    end
    fail_check("Report retry_count does not match decisions", errors) unless report["retry_count"].to_i == expected_retries
    expected_fallbacks = decisions.count { |decision| decision["selected_provider"] == "spacepayments" }
    fail_check("Report fallback_count does not match decisions", errors) unless report["fallback_count"].to_i == expected_fallbacks
  end
end

if errors.empty?
  puts "Release check passed: decisions and report are structurally and semantically complete."
  exit 0
end

warn "Release check failed with #{errors.size} error(s)."
exit 1
