# frozen_string_literal: true

require "fileutils"
require "json"
require "optparse"

require_relative "../route_lens"
require_relative "analytics/report_builder"

module RouteLens
  class CLI
    DEFAULTS = {
      providers: "data/providers.json",
      history: "data/operations_history.csv",
      queue: "data/operations_queue_10.json",
      policy: "config/routing.yml",
      preset: nil,
      decisions: "routing_decisions.json",
      report: "routing_report.json",
      seed: 2026,
      simulation: "deterministic",
      outcome_overrides: nil,
      quiet: false
    }.freeze

    def self.run(argv = ARGV, defaults: {})
      new(argv, defaults: defaults).run
    end

    def initialize(argv, defaults: {})
      @argv = argv.dup
      @options = DEFAULTS.merge(defaults)
    end

    def run
      parse_options!
      validate_output_paths!

      provider_snapshot = InputLoader.load_provider_snapshot(@options[:providers])
      providers = provider_snapshot.fetch("providers")
      initial_snapshot = provider_snapshot.merge("providers" => providers.map(&:snapshot))
      operations = InputLoader.load_operations(@options[:queue])
      history_rows = InputLoader.load_history(@options[:history])
      policy = Scoring::Policy.load(@options[:policy], preset: @options[:preset])
      simulator = OutcomeSimulator.new(
        seed: @options[:seed],
        mode: @options[:simulation],
        overrides: load_overrides(@options[:outcome_overrides])
      )

      run_result = Router.new(providers: providers, policy: policy, simulator: simulator).route(operations)
      history = Analytics::HistoryAnalyzer.new(history_rows).analyze
      report = Analytics::ReportBuilder.new(
        providers: initial_snapshot,
        operations: operations,
        decisions: run_result.decisions,
        final_state: { "providers" => run_result.provider_states.values },
        history: history,
        policy: policy
      ).build
      report["routing_attempts"] = run_result.routing_metrics

      atomic_json_write(@options[:decisions], run_result.decisions)
      atomic_json_write(@options[:report], report)
      print_summary(run_result.decisions, report) unless @options[:quiet]
      0
    rescue InputError, ConfigError, RoutingError, ArgumentError, Psych::Exception,
           Errno::EACCES, Errno::ENOENT => e
      warn "RouteLens error: #{e.message}"
      1
    end

    private

    def parse_options!
      parser = OptionParser.new do |options|
        options.banner = "Usage: ruby bin/route [options]"
        options.on("--providers PATH", "Provider snapshot JSON") { |value| @options[:providers] = value }
        options.on("--history PATH", "Operation-history CSV") { |value| @options[:history] = value }
        options.on("--queue PATH", "Operations queue JSON") { |value| @options[:queue] = value }
        options.on("--policy PATH", "Routing policy YAML") { |value| @options[:policy] = value }
        options.on("--preset NAME", "Named policy preset from the policy YAML") { |value| @options[:preset] = value }
        options.on("--decisions PATH", "Decision JSON output") { |value| @options[:decisions] = value }
        options.on("--report PATH", "Analytics JSON output") { |value| @options[:report] = value }
        options.on("--seed NUMBER", Integer, "Deterministic simulation seed") { |value| @options[:seed] = value }
        options.on("--simulation MODE", %w[approve_all deterministic], "approve_all or deterministic") do |value|
          @options[:simulation] = value
        end
        options.on("--outcome-overrides PATH", "Fixture-only outcome overrides JSON") do |value|
          @options[:outcome_overrides] = value
        end
        options.on("--quiet", "Suppress summary output") { @options[:quiet] = true }
        options.on("-h", "--help", "Show this help") do
          puts options
          throw :route_lens_help
        end
      end

      helped = catch(:route_lens_help) do
        parser.parse!(@argv)
        false
      end
      raise ArgumentError, "Unexpected arguments: #{@argv.join(' ')}" unless helped || @argv.empty?
      exit 0 if helped
    end

    def validate_output_paths!
      if File.expand_path(@options[:decisions]) == File.expand_path(@options[:report])
        raise ArgumentError, "Decision and report outputs must use different paths"
      end
    end

    def load_overrides(path)
      return {} if path.nil?

      overrides = JSON.parse(File.read(path))
      raise ArgumentError, "Outcome overrides must be a JSON object" unless overrides.is_a?(Hash)

      overrides
    rescue Errno::ENOENT, Errno::EACCES => e
      raise ArgumentError, "Cannot read outcome overrides #{path}: #{e.message}"
    rescue JSON::ParserError => e
      raise ArgumentError, "Invalid outcome overrides JSON in #{path}: #{e.message}"
    end

    def atomic_json_write(path, value)
      # Сначала записываем полный соседний файл и только затем переименовываем:
      # при ошибке пользователь не получит обрезанный итоговый JSON.
      absolute = File.expand_path(path)
      directory = File.dirname(absolute)
      FileUtils.mkdir_p(directory)
      temporary = "#{absolute}.tmp-#{Process.pid}"
      File.write(temporary, JSON.pretty_generate(value) + "\n")
      File.rename(temporary, absolute)
    ensure
      File.delete(temporary) if defined?(temporary) && File.exist?(temporary)
    end

    def print_summary(decisions, report)
      puts "RouteLens routed #{decisions.length} operation(s)."
      puts "Decisions: #{@options[:decisions]}"
      puts "Report:    #{@options[:report]}"
      puts "Approval rate: #{report.dig('outcomes', 'approval_rate_pct')}%"
      puts "Retries: #{report['retry_count']}; fallbacks: #{report['fallback_count']}"
    end
  end
end
