# frozen_string_literal: true

require_relative 'support'

module RouteLens
  module Analytics
    # Превращает метрики отчёта в рекомендации с числовым доказательством,
    # конкретным параметром для изменения и ожидаемым эффектом.
    #
    # Тексты (message, expected_impact) — русские, потому что отчёт читают
    # русскоязычные эксперты. Машинные поля (type, severity, provider,
    # parameter, коды правил) остаются английскими snake_case: на них
    # завязаны валидатор организаторов и словари Observatory.
    class RecommendationEngine
      CAPACITY_WARNING_PCT = 90.0
      CRITICAL_CAPACITY_PCT = 95.0
      CONVERSION_DRIFT_PCT = 10.0
      TARGET_DEVIATION_PCT = 10.0
      MINIMUM_HISTORY_SAMPLE = 5
      # Ниже этого числа операций отклонение доли от цели — шум выборки,
      # а не сигнал: на очереди из одной заявки любая доля равна 0% или 100%.
      MINIMUM_DISTRIBUTION_SAMPLE = 10
      # До этого объёма вывод помечается как предварительный с указанием n.
      LOW_CONFIDENCE_SAMPLE = 30
      # Пул считается исчерпанным, если загружены почти все внешние провайдеры
      # с лимитом и заметная часть выплат уже ушла на внутренний fallback.
      POOL_SATURATION_RATIO = 0.66
      POOL_FALLBACK_SHARE_PCT = 20.0
      # Вес априорной (заявленной) конверсии при сжатии исторической оценки.
      CONVERSION_PRIOR_WEIGHT = 20.0
      CONVERSION_CALIBRATION_PP = 5.0
      SELF_PROVIDER = 'spacepayments'

      # Жёсткое правило -> параметр провайдера, изменение которого его снимает.
      BLOCKING_PARAMETERS = {
        'amount_exceeds_limit' => 'limit_amount_max',
        'amount_below_minimum' => 'limit_amount_min',
        'daily_amount_limit_exceeded' => 'daily_amount_limit',
        'in_progress_amount_limit_exceeded' => 'in_progress_amount_limit',
        'in_progress_count_limit_exceeded' => 'in_progress_count_limit',
        'bank_not_in_list' => 'banks',
        'bank_excluded' => 'banks',
        'no_available_requisites' => 'available_requisites',
        'negative_margin_not_allowed' => 'merchant_margin_pct',
        'rate_limit_exceeded' => 'requests_per_minute_limit',
        'provider_inactive' => 'status',
        'traffic_disabled' => 'traffic_percentage'
      }.freeze

      # Русские пояснения к кодам правил. Сам код всегда остаётся в тексте:
      # оператор ищет по нему правило в конфигурации.
      RULE_LABELS = {
        'amount_exceeds_limit' => 'сумма выше максимума провайдера',
        'amount_below_minimum' => 'сумма ниже минимума провайдера',
        'daily_amount_limit_exceeded' => 'исчерпан дневной лимит суммы',
        'in_progress_amount_limit_exceeded' => 'исчерпан лимит суммы в работе',
        'in_progress_count_limit_exceeded' => 'исчерпан лимит операций в работе',
        'bank_not_in_list' => 'банк не поддерживается провайдером',
        'bank_excluded' => 'банк в списке исключений провайдера',
        'no_available_requisites' => 'нет свободных реквизитов',
        'negative_margin_not_allowed' => 'отрицательная маржа запрещена',
        'rate_limit_exceeded' => 'превышен лимит запросов в минуту',
        'provider_inactive' => 'провайдер неактивен',
        'traffic_disabled' => 'доля трафика равна нулю'
      }.freeze

      attr_reader :details

      def initialize(providers:, distribution:, projected_daily_utilization:, provider_metrics:,
                     history: nil, skip_reasons_by_provider: nil, policy: nil,
                     resilience: nil, total_operations: nil)
        @providers = Support.provider_list(providers)
        @distribution = Support.hash(distribution)
        @utilization = Support.hash(projected_daily_utilization)
        @provider_metrics = Support.hash(provider_metrics)
        @history = Support.hash(history)
        @skip_reasons_by_provider = Support.hash(skip_reasons_by_provider)
        @policy = policy
        @resilience = Support.hash(resilience)
        @total_operations = total_operations
        @details = []
      end

      def generate
        @details = []
        # Порядок важен: сначала проблема уровня пула, иначе оператор увидит
        # три совета «снизить долю» и не заметит, что снижать её некуда.
        add_pool_saturation_recommendations
        add_capacity_recommendations
        add_conversion_drift_recommendations
        add_conversion_calibration_recommendations
        add_historical_target_recommendations
        add_distribution_recommendations
        @details.map { |item| item['message'] }
      end
      alias call generate

      private

      # --- Насыщение внешнего пула -------------------------------------------

      def add_pool_saturation_recommendations
        return unless pool_saturated?

        limits = limited_external_providers
        current_total = limits.sum { |name| provider_limit(name) }
        deficit = fallback_amount
        proposed_total = Support.round(current_total + deficit)
        per_provider = limits.to_h do |name|
          limit = provider_limit(name)
          share = current_total.positive? ? limit / current_total : 0.0
          [name, { 'current' => Support.round(limit), 'proposed' => Support.round(limit + (deficit * share)) }]
        end
        saturated = saturated_external_providers

        message = format(
          'Внешний пул исчерпан: %<saturated>d из %<limited>s загружены на %<min_utilization>s и выше, ' \
          'а на внутренний %<self_provider>s ушло %<fallback_share>s выплат (%<fallback_count>s на %<fallback_amount>s). ' \
          'Снижение traffic_percentage здесь только увеличит поток на внутреннего провайдера. ' \
          'Поднять суммарный daily_amount_limit с %<current>s до %<proposed>s (%<breakdown>s), ' \
          'подключить дополнительную внешнюю ёмкость или перенести часть выплат в следующее дневное окно.',
          saturated: saturated.length,
          limited: Support.counted_ru(limits.length, 'внешнего провайдера с дневным лимитом',
                                      'внешних провайдеров с дневным лимитом', 'внешних провайдеров с дневным лимитом'),
          min_utilization: Support.percent_ru(CRITICAL_CAPACITY_PCT),
          self_provider: SELF_PROVIDER,
          fallback_share: Support.percent_ru(fallback_share_pct),
          fallback_count: Support.counted_ru(fallback_operations, 'выплата', 'выплаты', 'выплат'),
          fallback_amount: Support.amount_ru(deficit),
          current: Support.amount_ru(current_total),
          proposed: Support.amount_ru(proposed_total),
          breakdown: per_provider.map do |name, values|
            "#{name}: #{Support.amount_ru(values['current'])} → #{Support.amount_ru(values['proposed'])}"
          end.join('; ')
        )

        add_detail(
          type: 'pool_saturation', severity: 'critical', provider: nil,
          evidence: {
            'saturated_providers' => saturated,
            'external_providers_with_limit' => limits.length,
            'saturation_threshold_pct' => CRITICAL_CAPACITY_PCT,
            'external_headroom' => Support.round(limits.sum { |name| provider_headroom(name) }),
            'fallback_share_pct' => Support.round(fallback_share_pct),
            'fallback_operations' => fallback_operations,
            'fallback_amount' => Support.round(deficit)
          },
          action: {
            'parameter' => 'daily_amount_limit',
            'scope' => 'external_pool',
            'current' => Support.round(current_total),
            'proposed' => proposed_total,
            'per_provider' => per_provider,
            'alternatives' => %w[onboard_additional_provider_capacity defer_payouts_to_next_daily_window]
          },
          expected_impact: 'Вернуть выплаты внешним провайдерам вместо внутреннего fallback и снять причину отклонения от целевых долей.',
          message: message
        )
      end

      def pool_saturated?
        limits = limited_external_providers
        return false if limits.empty?
        return false if fallback_share_pct < POOL_FALLBACK_SHARE_PCT

        saturated_external_providers.length >= (limits.length * POOL_SATURATION_RATIO).ceil
      end

      def external_provider_names
        @providers.map { |provider| Support.provider_name(provider).to_s }
                  .reject { |name| name.empty? || name == SELF_PROVIDER }
      end

      def limited_external_providers
        external_provider_names.select { |name| provider_limit(name).positive? }
      end

      def saturated_external_providers
        limited_external_providers.select do |name|
          Support.number(Support.fetch(capacity_metrics(name), 'utilization_pct')) >= CRITICAL_CAPACITY_PCT
        end
      end

      def capacity_metrics(name)
        Support.hash(@utilization[name])
      end

      def provider_limit(name)
        Support.number(Support.fetch(capacity_metrics(name), 'limit'))
      end

      def provider_headroom(name)
        Support.number(Support.fetch(capacity_metrics(name), 'headroom'))
      end

      def fallback_share_pct
        Support.number(Support.fetch(@resilience, 'fallback_share_pct'))
      end

      def fallback_operations
        explicit = Support.fetch(@resilience, 'fallback_count')
        return Support.integer(explicit) unless explicit.nil?

        Support.integer(Support.fetch(Support.hash(@distribution[SELF_PROVIDER]), 'count'))
      end

      def fallback_amount
        Support.number(Support.fetch(Support.hash(@provider_metrics[SELF_PROVIDER]), 'amount'))
      end

      # --- Ёмкость отдельного провайдера -------------------------------------

      def add_capacity_recommendations
        # При исчерпанном пуле совет «снизить долю» вреден: высвобожденный
        # трафик некуда переносить, он уйдёт на внутреннего провайдера.
        # Проблема уже описана рекомендацией pool_saturation.
        return if pool_saturated?

        @providers.each do |provider|
          name = Support.provider_name(provider).to_s
          metrics = capacity_metrics(name)
          limit = Support.fetch(metrics, 'limit')
          next if name.empty? || limit.nil? || Support.number(limit).zero?

          utilization_pct = Support.number(Support.fetch(metrics, 'utilization_pct'))
          next if utilization_pct < CAPACITY_WARNING_PCT

          current_target = Support.number(Support.fetch(provider, 'traffic_percentage'))
          suggested_target = if utilization_pct >= CRITICAL_CAPACITY_PCT
                               [current_target, 10.0].min
                             else
                               (current_target / 2.0).round
                             end
          headroom = Support.number(Support.fetch(metrics, 'headroom'))
          severity = utilization_pct >= CRITICAL_CAPACITY_PCT ? 'critical' : 'warning'
          before_vector = traffic_target_vector
          after_vector = rebalance_target(before_vector, constrained_provider: name, proposed: suggested_target)
          message = format(
            '%<provider>s: дневной лимит использован на %<utilization>s (%<used>s из %<limit>s, запас %<headroom>s). ' \
            'Временно изменить traffic_percentage с %<current>s до %<suggested>s и перераспределить долю ' \
            'на %<receiver>s до сброса дневного лимита.',
            provider: name,
            utilization: Support.percent_ru(utilization_pct),
            used: Support.amount_ru(Support.fetch(metrics, 'used')),
            limit: Support.amount_ru(limit),
            headroom: Support.amount_ru(headroom),
            current: Support.percent_ru(current_target),
            suggested: Support.percent_ru(suggested_target),
            receiver: receiver_for(before_vector, name) || 'остальных внешних провайдеров'
          )
          add_detail(
            type: 'capacity_pressure', severity: severity, provider: name,
            evidence: {
              'utilization_pct' => Support.round(utilization_pct),
              'used' => Support.round(Support.fetch(metrics, 'used')),
              'limit' => Support.round(limit),
              'headroom' => Support.round(headroom)
            },
            action: {
              'parameter' => 'traffic_percentage',
              'current' => Support.round(current_target),
              'proposed' => Support.round(suggested_target),
              'target_vector_before' => before_vector,
              'target_vector_after' => after_vector,
              'duration' => 'until_daily_limit_reset'
            },
            expected_impact: 'Снизить риск жёстких исключений по дневному лимиту и сохранить остаток ёмкости для подходящих выплат.',
            message: message
          )
        end
      end

      # --- Конверсия ----------------------------------------------------------

      def add_conversion_drift_recommendations
        @providers.each do |provider|
          name = Support.provider_name(provider).to_s
          historical = historical_metrics(name)
          sample = Support.integer(Support.fetch(historical, 'operations'))
          next if name.empty? || sample < MINIMUM_HISTORY_SAMPLE

          live_pct = Support.number(Support.fetch(provider, 'conversion_24h')) * 100.0
          historical_pct = Support.number(Support.fetch(historical, 'approval_rate_pct'))
          drift = live_pct - historical_pct
          next if drift.abs < CONVERSION_DRIFT_PCT

          current_weight = policy_weight('conversion')
          # Нулевой вес уменьшать некуда: рекомендация без изменения параметра
          # бесполезна, поэтому она не выпускается.
          next unless current_weight.positive?

          proposed_weight = Support.round(current_weight / 2.0)

          message = format(
            '%<provider>s: conversion_24h %<live>s против исторического одобрения %<historical>s ' \
            '(разница %<drift>+.1f п.п., n=%<sample>d). Временно снизить policy.weights.conversion ' \
            'с %<current>.2f до %<proposed>.2f, пока окна метрик не сведены.',
            provider: name, live: Support.percent_ru(live_pct), historical: Support.percent_ru(historical_pct),
            drift: drift, sample: sample, current: current_weight, proposed: proposed_weight
          )
          add_detail(
            type: 'conversion_drift', severity: 'warning', provider: name,
            evidence: {
              'conversion_24h_pct' => Support.round(live_pct),
              'historical_approval_rate_pct' => Support.round(historical_pct),
              'difference_pp' => Support.round(drift),
              'historical_operations' => sample
            },
            action: {
              'parameter' => 'policy.weights.conversion',
              'current' => Support.round(current_weight),
              'proposed' => proposed_weight,
              'until' => 'live_and_historical_metric_windows_are_reconciled'
            },
            expected_impact: 'Не дать метрике с несогласованным окном измерения доминировать при выборе провайдера.',
            message: message
          )
        end
      end

      # Заявленная conversion_24h не подтверждается историей, поэтому
      # предлагается сжатая (shrunk) оценка: наблюдения и заявленное значение
      # смешиваются с весом CONVERSION_PRIOR_WEIGHT, иначе n=19 переоценивался бы.
      def add_conversion_calibration_recommendations
        @providers.each do |provider|
          name = Support.provider_name(provider).to_s
          historical = historical_metrics(name)
          sample = Support.integer(Support.fetch(historical, 'operations'))
          next if name.empty? || sample < MINIMUM_HISTORY_SAMPLE

          stated = Support.number(Support.fetch(provider, 'conversion_24h'))
          observed = Support.number(Support.fetch(historical, 'approval_rate_pct')) / 100.0
          blended = ((sample * observed) + (CONVERSION_PRIOR_WEIGHT * stated)) / (sample + CONVERSION_PRIOR_WEIGHT)
          shift_pp = (blended - stated) * 100.0
          next if shift_pp.abs < CONVERSION_CALIBRATION_PP

          parameter = "providers.#{name}.conversion_24h"
          message = format(
            '%<provider>s: заявленная conversion_24h %<stated>.2f не подтверждается историей — одобрено ' \
            '%<observed>s из %<sample>s. Установить %<parameter>s в %<proposed>.3f (сжатая оценка: ' \
            'n=%<sample_n>d против априорного веса %<prior>d, сдвиг %<shift>+.1f п.п.) либо пересчитать метрику на едином окне.',
            provider: name, stated: stated,
            observed: Support.percent_ru(Support.fetch(historical, 'approval_rate_pct')),
            sample: Support.counted_ru(sample, 'исторической операции', 'исторических операций', 'исторических операций'),
            parameter: parameter, proposed: blended.round(3), sample_n: sample,
            prior: CONVERSION_PRIOR_WEIGHT.to_i, shift: shift_pp
          )
          add_detail(
            type: 'conversion_calibration', severity: 'advisory', provider: name,
            evidence: {
              'stated_conversion_24h' => Support.round(stated, 3),
              'historical_approval_rate_pct' => Support.round(Support.fetch(historical, 'approval_rate_pct')),
              'historical_operations' => sample,
              'prior_weight' => CONVERSION_PRIOR_WEIGHT,
              'shrunk_conversion_24h' => blended.round(3),
              'shift_pp' => Support.round(shift_pp)
            },
            action: {
              'parameter' => parameter,
              'current' => Support.round(stated, 3),
              'proposed' => blended.round(3),
              'method' => 'shrunk_historical_estimate'
            },
            expected_impact: 'Дать скорингу конверсию, подтверждённую наблюдениями, вместо заявленной провайдером.',
            message: message
          )
        end
      end

      # --- Достижимость целей по истории --------------------------------------

      # История из 100 операций отвечает на вопрос, достигалась ли цель хоть
      # когда-нибудь. Этот вывод не зависит от размера текущей очереди.
      def add_historical_target_recommendations
        total = Support.integer(Support.fetch(@history, 'total_operations'))
        return if total < MINIMUM_DISTRIBUTION_SAMPLE

        @providers.each do |provider|
          name = Support.provider_name(provider).to_s
          next if name.empty? || name == SELF_PROVIDER

          historical = historical_metrics(name)
          sample = Support.integer(Support.fetch(historical, 'operations'))
          next if sample < MINIMUM_HISTORY_SAMPLE

          target = Support.number(Support.fetch(provider, 'traffic_percentage'))
          historical_share = Support.number(Support.fetch(historical, 'count_share_pct'))
          delta = historical_share - target
          next if delta.abs < TARGET_DEVIATION_PCT

          direction = delta.negative? ? 'ни разу не набиралась' : 'стабильно перевыполнялась'
          remedy = if delta.negative?
                     'либо устранить ограничение, из-за которого доля не набирается'
                   else
                     'либо перенести часть трафика на провайдеров, которые свою цель недобирают'
                   end
          message = format(
            '%<provider>s: за историю %<period>s фактическая доля операций %<historical>s при цели %<target>s ' \
            '(%<delta>+.1f п.п., %<sample>s, доля объёма %<volume>s) — цель %<direction>s. ' \
            'Привести traffic_percentage к %<proposed>s %<remedy>s.',
            provider: name, period: Support.fetch(@history, 'period') || 'наблюдений',
            historical: Support.percent_ru(historical_share), target: Support.percent_ru(target), delta: delta,
            sample: Support.counted_ru(sample, 'операция', 'операции', 'операций'),
            volume: Support.percent_ru(Support.fetch(historical, 'volume_share_pct')),
            direction: direction, proposed: Support.percent_ru(historical_share), remedy: remedy
          )
          add_detail(
            type: 'historical_target_gap', severity: 'advisory', provider: name,
            evidence: {
              'historical_count_share_pct' => Support.round(historical_share),
              'historical_volume_share_pct' => Support.round(Support.fetch(historical, 'volume_share_pct')),
              'target_pct' => Support.round(target),
              'delta_pct' => Support.round(delta),
              'historical_operations' => sample,
              'historical_total_operations' => total,
              'period' => Support.fetch(@history, 'period')
            },
            action: {
              'parameter' => 'traffic_percentage',
              'current' => Support.round(target),
              'proposed' => Support.round(historical_share),
              'basis' => 'historical_count_share'
            },
            expected_impact: 'Согласовать целевую долю с исторически достижимой или явно назвать ограничение, которое мешает цели.',
            message: message
          )
        end
      end

      # --- Отклонение долей в текущем запуске ---------------------------------

      def add_distribution_recommendations
        total = routed_operations
        return add_insufficient_sample_detail(total) if total < MINIMUM_DISTRIBUTION_SAMPLE

        @providers.each do |provider|
          name = Support.provider_name(provider).to_s
          next if name.empty? || name == SELF_PROVIDER

          distribution = Support.hash(@distribution[name])
          delta = Support.number(Support.fetch(distribution, 'delta_pct'))
          next if delta.abs < TARGET_DEVIATION_PCT

          blocking = dominant_blocking_rule(name)
          if delta.negative? && blocking_explains_gap?(blocking, delta, total)
            add_infeasible_target_detail(provider, name, distribution, blocking, total)
          else
            add_share_deviation_detail(provider, name, distribution, delta, total)
          end
        end
      end

      def add_insufficient_sample_detail(total)
        message = format(
          'Выборка слишком мала для выводов о долях: в запуске %<total>s при минимуме %<minimum>d. ' \
          'Отклонения фактических долей от traffic_percentage в этом запуске статистически незначимы — ' \
          'не менять целевые доли, пока не накоплено хотя бы %<minimum>d операций.',
          total: Support.counted_ru(total, 'операция', 'операции', 'операций'),
          minimum: MINIMUM_DISTRIBUTION_SAMPLE
        )
        add_detail(
          type: 'insufficient_sample', severity: 'advisory', provider: nil,
          evidence: {
            'operations' => total,
            'minimum_operations' => MINIMUM_DISTRIBUTION_SAMPLE,
            'deviation_threshold_pct' => TARGET_DEVIATION_PCT
          },
          action: {
            # Меняется не цель, а объём наблюдений: до него любые правки долей
            # опираются на шум.
            'parameter' => 'minimum_sample_operations',
            'current' => total,
            'proposed' => MINIMUM_DISTRIBUTION_SAMPLE,
            'deferred_parameter' => 'traffic_percentage',
            'decision' => 'defer_target_changes_until_minimum_sample'
          },
          expected_impact: 'Не давать менять бизнес-цели на основании шума маленькой выборки.',
          message: message
        )
      end

      # Цель недостижима, если недобор объясняется жёсткими правилами: столько
      # операций провайдер физически не мог принять. Тогда менять надо параметр
      # правила, а не долю трафика.
      def add_infeasible_target_detail(provider, name, distribution, blocking, total)
        reason = blocking['reason']
        parameter = BLOCKING_PARAMETERS.fetch(reason, 'eligibility_rules')
        actual = Support.number(Support.fetch(distribution, 'share_pct'))
        target = Support.number(Support.fetch(distribution, 'target_pct'))
        delta = Support.number(Support.fetch(distribution, 'delta_pct'))
        proposal = blocking_parameter_proposal(provider, name, reason, blocking)
        blocked = Support.integer(blocking['operations'])

        primary = if proposal.nil?
                    format('пересмотреть %<parameter>s (сейчас %<current>s)',
                           parameter: parameter, current: format_parameter_value(current_parameter_value(provider, parameter)))
                  else
                    format('изменить %<parameter>s с %<current>s на %<proposed>s (основание: %<basis>s)',
                           parameter: parameter,
                           current: format_parameter_value(proposal['current']),
                           proposed: format_parameter_value(proposal['proposed']),
                           basis: proposal['basis'])
                  end

        message = format(
          '%<provider>s: доля операций %<actual>s при цели %<target>s (%<delta>+.1f п.п.); ' \
          'жёстким правилом %<reason>s (%<label>s) отклонено %<blocked>s. ' \
          'Цель недостижима без изменения ограничения: %<primary>s ' \
          'либо признать достижимой долю %<feasible>s и снизить traffic_percentage до неё.%<confidence>s',
          provider: name, actual: Support.percent_ru(actual), target: Support.percent_ru(target), delta: delta,
          blocked: Support.counted_ru(blocked, 'операция', 'операции', 'операций'),
          reason: reason, label: RULE_LABELS.fetch(reason, 'жёсткое ограничение'),
          primary: primary, feasible: Support.percent_ru(actual),
          confidence: confidence_note(total)
        )

        # Если числовое значение параметра вывести не из чего, действием
        # становится приведение цели к достижимой доле: рекомендация обязана
        # содержать изменение, а не совет «оставить как есть».
        action = if proposal.nil?
                   {
                     'parameter' => 'traffic_percentage',
                     'current' => Support.round(target),
                     'proposed' => Support.round(actual),
                     'direction' => 'decrease',
                     'blocking_rule' => reason,
                     'blocked_parameter' => parameter
                   }
                 else
                   {
                     'parameter' => parameter,
                     'current' => proposal['current'],
                     'proposed' => proposal['proposed'],
                     'direction' => proposal['direction'],
                     'blocking_rule' => reason,
                     'alternative' => {
                       'parameter' => 'traffic_percentage',
                       'current' => Support.round(target),
                       'proposed' => Support.round(actual)
                     }
                   }
                 end
        add_detail(
          type: 'infeasible_count_target', severity: 'warning', provider: name,
          evidence: {
            'actual_share_pct' => Support.round(actual),
            'target_pct' => Support.round(target),
            'delta_pct' => Support.round(delta),
            'blocking_rule' => reason,
            'blocked_operations' => blocked,
            'shortfall_operations' => shortfall_operations(delta, total),
            'sample_operations' => total,
            'confidence' => confidence_level(total),
            'historical_count_share_pct' => historical_share(name)
          },
          action: action,
          expected_impact: 'Снять реальное ограничение или зафиксировать достижимую цель вместо недостижимой.',
          message: message
        )
      end

      # Провайдер допустим, но проигрывает по скорингу: работает вес цели,
      # а не жёсткое правило, поэтому меняется policy.weights.count_target_gain.
      def add_share_deviation_detail(provider, name, distribution, delta, total)
        actual = Support.number(Support.fetch(distribution, 'share_pct'))
        target = Support.number(Support.fetch(distribution, 'target_pct'))
        current_weight = policy_weight('count_target_gain')
        proposed_weight = Support.round([current_weight * 1.5, current_weight + 0.5].max)
        direction = delta.negative? ? 'недобирает цель' : 'превышает цель'
        type = delta.negative? ? 'count_share_below_target' : 'count_share_above_target'
        blocked = blocked_operations_total(name)
        exclusions = if blocked.zero?
                       'жёстких исключений нет'
                     else
                       "жёстко исключено #{Support.counted_ru(blocked, 'операция', 'операции', 'операций')}"
                     end

        message = format(
          '%<provider>s %<direction>s: доля операций %<actual>s при цели %<target>s (%<delta>+.1f п.п.), ' \
          '%<blocked>s — ограничения этого не объясняют. ' \
          'Увеличить policy.weights.count_target_gain с %<current>.2f до %<proposed>.2f, ' \
          'чтобы выравнивание долей сильнее влияло на выбор.%<confidence>s',
          provider: name, direction: direction, actual: Support.percent_ru(actual),
          target: Support.percent_ru(target), delta: delta,
          blocked: exclusions,
          current: current_weight, proposed: proposed_weight, confidence: confidence_note(total)
        )
        add_detail(
          type: type, severity: 'advisory', provider: name,
          evidence: {
            'actual_share_pct' => Support.round(actual),
            'target_pct' => Support.round(target),
            'delta_pct' => Support.round(delta),
            'hard_exclusion_operations' => blocked,
            'sample_operations' => total,
            'confidence' => confidence_level(total),
            'historical_count_share_pct' => historical_share(name)
          },
          action: {
            'parameter' => 'policy.weights.count_target_gain',
            'current' => Support.round(current_weight),
            'proposed' => proposed_weight,
            'direction' => 'increase'
          },
          expected_impact: 'Усилить притяжение к целевым долям там, где выбор определяется скорингом, а не ограничениями.',
          message: message
        )
      end

      def confidence_level(total)
        total < LOW_CONFIDENCE_SAMPLE ? 'low' : 'normal'
      end

      def confidence_note(total)
        return '' unless confidence_level(total) == 'low'

        format(' Вывод предварительный: выборка n=%<total>d меньше %<threshold>d операций.',
               total: total, threshold: LOW_CONFIDENCE_SAMPLE)
      end

      def routed_operations
        return Support.integer(@total_operations) unless @total_operations.nil?

        @distribution.values.sum { |metrics| Support.integer(Support.fetch(metrics, 'count')) }
      end

      def shortfall_operations(delta, total)
        (delta.abs * total / 100.0).round
      end

      def blocked_operations(name)
        Support.hash(Support.fetch(Support.hash(@provider_metrics[name]), 'blocked_operations'))
      end

      def blocked_operations_total(name)
        blocked = blocked_operations(name)
        return Support.integer(Support.fetch(blocked, 'operations')) unless Support.fetch(blocked, 'operations').nil?

        # Запасной источник: счётчики попыток, если детализация не передана.
        Support.hash(@skip_reasons_by_provider[name]).values.sum { |count| Support.integer(count) }
      end

      def dominant_blocking_rule(name)
        reasons = Support.hash(Support.fetch(blocked_operations(name), 'reasons'))
        if reasons.empty?
          fallback = Support.hash(@skip_reasons_by_provider[name])
          dominant = fallback.max_by { |reason, count| [Support.integer(count), reason] }
          return nil if dominant.nil?

          return { 'reason' => dominant[0], 'operations' => Support.integer(dominant[1]), 'metrics' => {} }
        end

        dominant = reasons.max_by { |reason, metrics| [Support.integer(Support.fetch(metrics, 'operations')), reason] }
        return nil if dominant.nil?

        { 'reason' => dominant[0], 'operations' => Support.integer(Support.fetch(dominant[1], 'operations')),
          'metrics' => Support.hash(dominant[1]) }
      end

      def blocking_explains_gap?(blocking, delta, total)
        return false if blocking.nil?

        blocking['operations'] >= [shortfall_operations(delta, total), 1].max
      end

      # Числовое предложение выводится из сумм и банков заблокированных операций:
      # p90 разблокирует девять из десяти отклонённых заявок.
      def blocking_parameter_proposal(provider, name, reason, blocking)
        metrics = Support.hash(blocking['metrics'])
        case reason
        when 'amount_exceeds_limit'
          proposal_from(provider, 'limit_amount_max', Support.fetch(metrics, 'amount_p90'), 'increase',
                        'p90 отклонённых сумм')
        when 'amount_below_minimum'
          proposal_from(provider, 'limit_amount_min', Support.fetch(metrics, 'amount_p10'), 'decrease',
                        'p10 отклонённых сумм')
        when 'daily_amount_limit_exceeded'
          current = Support.number(current_parameter_value(provider, 'daily_amount_limit'))
          proposal_from(provider, 'daily_amount_limit',
                        current + Support.number(Support.fetch(metrics, 'amount_sum')), 'increase',
                        'текущий лимит плюс объём отклонённых выплат')
        when 'in_progress_amount_limit_exceeded'
          current = Support.number(current_parameter_value(provider, 'in_progress_amount_limit'))
          proposal_from(provider, 'in_progress_amount_limit',
                        current + Support.number(Support.fetch(metrics, 'amount_p90')), 'increase',
                        'текущий лимит плюс p90 отклонённых сумм')
        when 'bank_not_in_list'
          banks = Support.hash(Support.fetch(metrics, 'banks')).keys
          return nil if banks.empty?

          current = Array(current_parameter_value(provider, 'banks'))
          { 'current' => current, 'proposed' => (current + banks).uniq, 'direction' => 'extend',
            'basis' => "банки отклонённых заявок: #{banks.join(', ')}" }
        when 'no_available_requisites'
          current = Support.integer(current_parameter_value(provider, 'available_requisites'))
          { 'current' => current, 'proposed' => current + 1, 'direction' => 'increase',
            'basis' => 'минимум один свободный реквизит' }
        else
          nil
        end
      end

      def proposal_from(provider, parameter, value, direction, basis)
        return nil if value.nil? || Support.number(value).zero?

        { 'current' => current_parameter_value(provider, parameter), 'proposed' => Support.round(value),
          'direction' => direction, 'basis' => basis }
      end

      def current_parameter_value(provider, parameter)
        Support.fetch(provider, parameter)
      end

      def format_parameter_value(value)
        case value
        when nil then 'не задан'
        when Array then value.empty? ? 'пустой список' : value.join(', ')
        when Numeric then Support.amount_ru(value)
        else value.to_s
        end
      end

      def historical_metrics(name)
        Support.hash(Support.hash(Support.fetch(@history, 'providers', {}))[name])
      end

      def historical_share(name)
        value = Support.fetch(historical_metrics(name), 'count_share_pct')
        value.nil? ? nil : Support.round(value)
      end

      def add_detail(type:, severity:, provider:, evidence:, action:, expected_impact:, message:)
        @details << {
          'type' => type,
          'severity' => severity,
          'provider' => provider,
          'evidence' => evidence,
          'action' => action,
          'expected_impact' => expected_impact,
          'message' => message
        }
      end

      def policy_weight(name)
        return 0.0 unless @policy&.respond_to?(:weights)

        Support.number(Support.fetch(@policy.weights, name))
      end

      def traffic_target_vector
        external = @providers.reject { |provider| Support.provider_name(provider).to_s == SELF_PROVIDER }
        vector = external.to_h do |provider|
          [Support.provider_name(provider).to_s, Support.number(Support.fetch(provider, 'traffic_percentage'))]
        end
        normalize_vector(vector)
      end

      def normalize_vector(vector)
        total = vector.values.sum
        return vector.transform_values { 0.0 } unless total.positive?

        normalized = vector.transform_values { |value| Support.round(value * 100.0 / total) }
        correction = Support.round(100.0 - normalized.values.sum)
        first = normalized.keys.first
        normalized[first] = Support.round(normalized[first] + correction) if first
        normalized
      end

      def receiver_for(vector, constrained_provider)
        candidates = vector.keys.reject { |name| name == constrained_provider }
        candidates.min_by do |name|
          utilization = Support.fetch(capacity_metrics(name), 'utilization_pct')
          utilization.nil? ? -1.0 : Support.number(utilization)
        end
      end

      def rebalance_target(vector, constrained_provider:, proposed:)
        # Высвобождённая доля уходит наименее загруженному внешнему провайдеру,
        # после чего весь вектор нормализуется ровно до 100%.
        result = vector.dup
        current = Support.number(result[constrained_provider])
        result[constrained_provider] = [Support.number(proposed), current].min
        released = current - result[constrained_provider]
        receiver = receiver_for(result, constrained_provider)
        result[receiver] = Support.round(result.fetch(receiver, 0.0) + released) if receiver
        normalize_vector(result)
      end
    end
  end
end
