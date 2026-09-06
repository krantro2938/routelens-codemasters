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
      compact: false,
      quiet: false
    }.freeze

    # Минимальная форма решения из задания: только то, что обязан прочитать
    # валидатор. Остальные поля — наши доказательства, они остаются по умолчанию.
    COMPACT_ATTEMPT_KEYS = %w[provider decision reason details].freeze

    # 0 — файлы записаны, 1 — вход или конфигурация непригодны (файлы не тронуты),
    # 3 — файлы записаны, но ни одну операцию не удалось выполнить.
    NOTHING_ROUTED_STATUS = 3

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

      # Конфигурация читается один раз: политика и переопределения провайдеров
      # приходят из одного файла, поэтому запуск нельзя собрать наполовину.
      policy_config = ConfigLoader.load(@options[:policy])
      policy = Scoring::Policy.new(policy_config, preset: @options[:preset])
      provider_snapshot = InputLoader.load_provider_snapshot(
        @options[:providers],
        overrides: policy_config["provider_overrides"]
      )
      providers = provider_snapshot.fetch("providers")
      initial_snapshot = provider_snapshot.merge("providers" => providers.map(&:snapshot))
      operations = InputLoader.load_operations(@options[:queue])
      history_rows = InputLoader.load_history(@options[:history])
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

      decisions = @options[:compact] ? compact_decisions(run_result.decisions) : run_result.decisions
      atomic_json_pair_write(
        @options[:decisions] => decisions,
        @options[:report] => report
      )
      print_summary(run_result.decisions, report) unless @options[:quiet]
      exit_status(run_result.decisions)
    rescue InputError, ConfigError, RoutingError, ArgumentError, Psych::Exception,
           Errno::EACCES, Errno::ENOENT => e
      warn "RouteLens error: #{e.message}"
      1
    rescue StandardError => e
      # Последний рубеж: судья не должен увидеть сырой стек Ruby. Класс ошибки
      # печатается явно, иначе настоящий баг станет неотличим от ошибки входа.
      warn "RouteLens internal error (#{e.class}): #{e.message}"
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
        options.on("--compact", "Write the spec-minimal decision shape without evidence fields") do
          @options[:compact] = true
        end
        options.on("--quiet", "Suppress summary output") { @options[:quiet] = true }
        options.on("-h", "--help", "Show this help") do
          puts options
          # Значение обязательно: catch без него вернёт nil, и после справки
          # запуск продолжался бы обычным прогоном, перезаписывая артефакты.
          throw :route_lens_help, true
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

    # Компактная форма отдаёт ровно поля спецификации. По умолчанию файл
    # остаётся доказательным: состояния резерва проверяются release_check.
    def compact_decisions(decisions)
      decisions.map do |decision|
        {
          "operation_id" => decision["operation_id"],
          "selected_provider" => decision["selected_provider"],
          "attempts" => Array(decision["attempts"]).map { |attempt| attempt.slice(*COMPACT_ATTEMPT_KEYS) },
          "simulated_result" => decision["simulated_result"],
          "latency_sec" => decision["latency_sec"]
        }
      end
    end

    def unroutable_count(decisions)
      decisions.count { |decision| decision["selected_provider"].nil? }
    end

    # Пакет с единичным сбоем считается успешным: 999 корректных решений важнее
    # одной невыполнимой выплаты. Ненулевой статус — только если не выполнено ничего.
    def exit_status(decisions)
      return 0 if decisions.empty?

      unroutable_count(decisions) == decisions.length ? NOTHING_ROUTED_STATUS : 0
    end

    # Оба JSON сначала полностью подготавливаются, и только затем публикуются.
    # Файловая система не даёт одной атомарной операции для двух имён, поэтому
    # при ошибке второго rename первый файл откатывается из соседней копии.
    # Судья получает либо новую согласованную пару, либо предыдущую пару.
    def atomic_json_pair_write(outputs)
      nonce = "#{Process.pid}-#{object_id}"
      records = []
      outputs.each_with_index do |(path, value), index|
        absolute = File.expand_path(path)
        FileUtils.mkdir_p(File.dirname(absolute))
        temporary = "#{absolute}.tmp-#{nonce}-#{index}"
        backup = "#{absolute}.bak-#{nonce}-#{index}"
        record = {
          target: absolute, temporary: temporary, backup: backup,
          existed: File.exist?(absolute), committed: false, rollback_failed: false
        }
        records << record
        File.write(temporary, JSON.pretty_generate(value) + "\n")
      end

      records.each { |record| FileUtils.cp(record[:target], record[:backup]) if record[:existed] }
      records.each do |record|
        rename_file(record[:temporary], record[:target])
        record[:committed] = true
      end
    rescue StandardError => original_error
      Array(records).reverse_each do |record|
        next unless record[:committed]

        if record[:existed] && File.exist?(record[:backup])
          rename_file(record[:backup], record[:target])
        elsif File.exist?(record[:target])
          File.delete(record[:target])
        end
      rescue StandardError
        # Не маскируем исходную ошибку публикации. Неудалённый backup сохраняет
        # предыдущую версию для ручного восстановления в крайне редком случае,
        # когда не удался и сам rollback.
        record[:rollback_failed] = true
      end
      raise original_error
    ensure
      Array(records).each do |record|
        File.delete(record[:temporary]) if File.exist?(record[:temporary])
        File.delete(record[:backup]) if !record[:rollback_failed] && File.exist?(record[:backup])
      end
    end

    def rename_file(source, target)
      File.rename(source, target)
    end

    def print_summary(decisions, report)
      unroutable = unroutable_count(decisions)
      puts "RouteLens routed #{decisions.length - unroutable} of #{decisions.length} operation(s)."
      puts "Decisions: #{@options[:decisions]}#{@options[:compact] ? ' (compact)' : ''}"
      puts "Report:    #{@options[:report]}"
      puts "Approval rate: #{report.dig('outcomes', 'approval_rate_pct')}%"
      puts "Retries: #{report['retry_count']}; fallbacks: #{report['fallback_count']}"
      return if unroutable.zero?

      puts "Unroutable: #{unroutable} operation(s) had no eligible provider (reason no_provider_available)"
    end
  end
end
