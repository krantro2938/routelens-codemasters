# frozen_string_literal: true

require_relative "../test_helper"
require "route_lens"

# Регрессии на КАЧЕСТВО маршрутизации, а не на её механику.
#
# Остальные тесты проверяют, что движок работает: журнал попыток заполнен,
# резерв снимается, fallback срабатывает. Ни один из них не проверял, что
# движок решает поставленную задачу — приближает распределение к целям и
# уважает собственные настройки. Именно в этом зазоре выжило целое семейство
# ошибок (пресет conversion_first выбирал провайдера с худшей конверсией,
# capacity_first и conversion_first давали побайтово одинаковый маршрут,
# ручка volume_targets была мёртвой). Здесь каждый тест закрывает одну из них.
class RoutingQualityTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  # Достижимый оптимум по количеству на публичной очереди: vipay допустим
  # ровно для {op_101,105,106,109}, payflow — для {op_101,102,107,110},
  # op_103/104/108 жёстко привязаны к quickpay, op_107 — к payflow. Лучший
  # реально достижимый раскол 4/3/3 против целей 40/35/25 даёт 10.0 п.п.
  FEASIBLE_COUNT_ERROR_PP = 10.0

  def setup
    @config = RouteLens::ConfigLoader.load(File.join(ROOT, "config/routing.yml"))
    @operations = RouteLens::InputLoader.load_operations(File.join(ROOT, "data/operations_queue_10.json"))
    @snapshot = RouteLens::InputLoader.load_provider_snapshot(
      File.join(ROOT, "data/providers.json"),
      overrides: @config["provider_overrides"]
    )
    @provider_attributes = @snapshot.fetch("providers").map(&:snapshot)
    @conversions = @provider_attributes.to_h do |attributes|
      [attributes.fetch("payment_system"), attributes.fetch("conversion_24h").to_f]
    end
  end

  # (a) Conversion возвращала сырое значение, пока latency и priority уже были
  # нормализованы по текущим кандидатам. Разрыв в 9 секунд задержки перевешивал
  # разрыв в 12 пунктов конверсии, и «пресет по конверсии» ставил первым
  # провайдера с САМОЙ НИЗКОЙ конверсией.
  #
  # Проверяем ранжирование, а не итогового исполнителя: при deterministic
  # попытка победителя может завершиться отказом, и повтор уйдёт к другому —
  # это правильное поведение и оно не должно делать тест плавающим.
  def test_conversion_first_ranks_the_highest_converting_eligible_provider_first
    decisions = route(preset: "conversion_first").decisions
    contested = 0

    decisions.each do |decision|
      pool = first_round_ranking(decision)
      next if pool.length < 2

      contested += 1
      leader = pool.min_by { |attempt| attempt.fetch("rank") }.fetch("provider")
      best = pool.max_by { |attempt| @conversions.fetch(attempt.fetch("provider")) }.fetch("provider")

      assert_equal best, leader,
                   "#{decision['operation_id']}: пресет по конверсии поставил первым #{leader} " \
                   "(conversion_24h #{@conversions.fetch(leader)}), хотя доступен #{best} " \
                   "(conversion_24h #{@conversions.fetch(best)})"
    end

    # Тест обязан что-то проверить: op_101 — операция, где допустимы все три
    # внешних провайдера, поэтому спорных ранжирований не может быть меньше.
    assert_operator contested, :>=, 3, "не найдено ни одной операции с конкуренцией провайдеров"
    assert_equal 3, first_round_ranking(decisions.first).length
  end

  # (b) capacity_first и conversion_first выдавали побайтово одинаковый вектор
  # назначений: пресеты существовали только в конфиге, но не в поведении.
  def test_presets_with_opposite_goals_do_not_collapse_to_the_same_routing
    capacity = assignments(route(preset: "capacity_first"))
    conversion = assignments(route(preset: "conversion_first"))

    refute_equal capacity, conversion,
                 "capacity_first и conversion_first дали одинаковый маршрут: пресеты не влияют на выбор"
    # Различие должно быть содержательным, а не в одной операции из десяти.
    differences = capacity.count { |operation_id, provider| conversion.fetch(operation_id) != provider }
    assert_operator differences, :>=, 2
  end

  # (c) Смена volume_targets с 50/25/25 на 100/0/0 не меняла ничего: ручка была
  # мёртвой, потому что цели объёма брались не из конфигурации.
  #
  # Жадный выбор по одной операции на очереди из десяти НЕ монотонен глобально
  # (перехватив мелкую выплату, провайдер теряет крупную), поэтому инвариант
  # формулируется на крайних точках — там он честен и обязан выполняться:
  # весь целевой объём на провайдера не может дать ему МЕНЬШЕ денег, чем
  # нулевая цель, и хотя бы для одного провайдера обязан дать строго больше.
  def test_volume_target_knob_moves_volume_toward_the_targeted_provider
    moved = 0

    %w[vipay payflow quickpay].each do |name|
      others = %w[vipay payflow quickpay] - [name]
      full = volume_shares(route(config: with_volume_targets(name => 100, others[0] => 0, others[1] => 0)))
      none = volume_shares(route(config: with_volume_targets(name => 0, others[0] => 50, others[1] => 50)))

      assert_operator full.fetch(name, 0.0), :>=, none.fetch(name, 0.0),
                      "полная цель объёма для #{name} дала ему меньше денег, чем нулевая"
      moved += 1 if full.fetch(name, 0.0) > none.fetch(name, 0.0)
    end

    assert_equal 3, moved, "ручка volume_targets не сдвинула денежный объём ни для одного провайдера"
  end

  # (d) Новый провайдер с лучшей конверсией и целью в 20% трафика получал НОЛЬ
  # операций, если ему не выдавали вершину каскада. Цель по количеству обязана
  # работать независимо от priority — иначе подключение провайдера требует
  # ручной перенастройки каскада.
  def test_new_provider_with_a_traffic_target_receives_operations_at_any_priority
    counts_by_priority = [1, 5, 9].to_h do |priority|
      result = route(providers: providers_with_newcomer(priority))
      [priority, assignments(result).values.tally]
    end

    counts_by_priority.each do |priority, counts|
      share = counts.fetch("newpay", 0) * 100.0 / @operations.length

      assert_operator counts.fetch("newpay", 0), :>, 0,
                      "новый провайдер с целью 20% не получил ни одной операции при priority=#{priority}"
      assert_in_delta 20.0, share, 10.0,
                      "доля нового провайдера при priority=#{priority} далека от его цели в 20%"
    end

    # Место в каскаде не должно менять ОБЪЁМ работы, который получает
    # провайдер: за это отвечает цель по количеству, а priority лишь
    # разрешает ничьи.
    assert_equal 1, counts_by_priority.values.map { |counts| counts.fetch("newpay", 0) }.uniq.length,
                 "количество операций нового провайдера зависит от его priority"
  end

  # (e) Политика по умолчанию проигрывала собственному пресету cascade сразу по
  # двум измеряемым целям задания. Пресеты — это витрина стратегий, а не более
  # удачная политика, поэтому дефолт обязан быть не хуже любого из них.
  def test_default_policy_is_not_beaten_by_its_own_presets
    balanced = route
    balanced_count = count_error(balanced)
    balanced_volume = volume_error(balanced)

    assert_in_delta FEASIBLE_COUNT_ERROR_PP, balanced_count, 0.01,
                    "ошибка по количеству отклонилась от достижимого оптимума"

    %w[conversion_first cascade capacity_first].each do |preset|
      scenario = route(preset: preset)

      assert_operator balanced_count, :<=, count_error(scenario),
                      "пресет #{preset} лучше политики по умолчанию по цели количества"
      assert_operator balanced_volume, :<=, volume_error(scenario),
                      "пресет #{preset} лучше политики по умолчанию по цели объёма"
    end
  end

  private

  # approve_all убирает влияние смоделированных отказов: расхождение между
  # сценариями объясняется только политикой выбора, а не удачей симулятора.
  def route(preset: nil, config: @config, providers: nil)
    providers ||= fresh_providers
    RouteLens::Router.new(
      providers: providers,
      policy: RouteLens::Scoring::Policy.new(config, preset: preset),
      simulator: RouteLens::OutcomeSimulator.new(mode: "approve_all")
    ).route(@operations)
  end

  def fresh_providers
    @provider_attributes.map { |attributes| RouteLens::ProviderState.new(deep_copy(attributes)) }
  end

  # Новый провайдер добавляется так же, как это сделал бы интегратор: доли
  # существующих пересчитаны, вектор целей по-прежнему даёт 100%.
  def providers_with_newcomer(priority)
    rebalanced = { "vipay" => 32, "payflow" => 28, "quickpay" => 20 }
    providers = @provider_attributes.map do |attributes|
      copy = deep_copy(attributes)
      name = copy.fetch("payment_system")
      copy["traffic_percentage"] = rebalanced.fetch(name) if rebalanced.key?(name)
      RouteLens::ProviderState.new(copy)
    end
    providers + [RouteLens::ProviderState.new(newcomer_attributes(priority))]
  end

  def newcomer_attributes(priority)
    {
      "payment_system" => "newpay",
      "status" => "active",
      "traffic_percentage" => 20,
      "priority" => priority,
      "limit_amount_min" => 500,
      "limit_amount_max" => 200_000,
      "daily_amount_limit" => 5_000_000,
      "daily_approved_amount" => 0,
      "in_progress_count_limit" => 20,
      "in_progress_count" => 0,
      "in_progress_amount_limit" => 2_000_000,
      "in_progress_amount" => 0,
      "available_requisites" => 15,
      "conversion_24h" => 0.95,
      "avg_latency_sec" => 40,
      "banks" => [],
      "exclude_banks" => false,
      "provider_margin_pct" => 0.9,
      "merchant_margin_pct" => 1.5,
      "allow_negative_agreement" => false
    }
  end

  def with_volume_targets(targets)
    @config.merge("volume_targets" => targets.transform_keys(&:to_s))
  end

  def first_round_ranking(decision)
    decision.fetch("attempts").select { |attempt| attempt["round"] == 1 && attempt["rank"] }
  end

  def assignments(result)
    result.decisions.to_h { |decision| [decision.fetch("operation_id"), decision["selected_provider"]] }
  end

  # Знаменатель целей — только внешние назначения, ровно как в скоринге
  # и в отчёте: fallback не участвует в целевом распределении.
  def external_decisions(result)
    result.decisions.reject do |decision|
      provider = decision["selected_provider"]
      provider.nil? || provider == RouteLens::ProviderState::SELF_PROVIDER
    end
  end

  def count_error(result)
    external = external_decisions(result)
    total = external.length.to_f
    count_targets.sum do |name, target|
      (external.count { |decision| decision["selected_provider"] == name } * 100.0 / total - target).abs
    end.round(2)
  end

  def volume_error(result)
    shares = volume_shares(result)
    volume_targets.sum { |name, target| (shares.fetch(name, 0.0) - target).abs }.round(2)
  end

  def volume_shares(result)
    external = external_decisions(result)
    total = external.sum { |decision| amount_of(decision) }
    return {} unless total.positive?

    external.group_by { |decision| decision.fetch("selected_provider") }
            .transform_values { |group| group.sum { |decision| amount_of(decision) } * 100.0 / total }
  end

  def amount_of(decision)
    @amounts ||= @operations.to_h { |operation| [operation.fetch("operation_id"), operation.fetch("amount").to_f] }
    @amounts.fetch(decision.fetch("operation_id"))
  end

  def count_targets
    @count_targets ||= @provider_attributes.reject { |attributes| self_provider?(attributes) }
                                           .to_h { |a| [a.fetch("payment_system"), a.fetch("traffic_percentage").to_f] }
  end

  def volume_targets
    @volume_targets ||= @config.fetch("volume_targets").transform_values(&:to_f)
  end

  def self_provider?(attributes)
    attributes.fetch("payment_system") == RouteLens::ProviderState::SELF_PROVIDER
  end

  def deep_copy(value)
    Marshal.load(Marshal.dump(value))
  end
end
