# frozen_string_literal: true

require_relative "../test_helper_scoring"
require "route_lens/provider_state"
require "route_lens/scoring/support"

class ScoringSupportTest < Minitest::Test
  include ScoringFixtures

  Double = Struct.new(:payment_system)

  def test_fetch_returns_the_default_for_keys_that_collide_with_collection_methods
    band = { "min" => 50_001 }

    # Hash отвечает на :max, :min, :count и :first, поэтому произвольный
    # public_send возвращал бы внутренности коллекции вместо значения по
    # умолчанию: неполный диапазон падал на amount_preference с NoMethodError.
    assert_equal 50_001, RouteLens::Scoring::Support.fetch(band, :min, 0)
    assert_nil RouteLens::Scoring::Support.fetch(band, :max, nil)
    assert_equal 7, RouteLens::Scoring::Support.fetch(band, :count, 7)
    assert_equal 7, RouteLens::Scoring::Support.fetch({}, :first, 7)
    assert_equal 7, RouteLens::Scoring::Support.fetch({}, :sum, 7)
  end

  # Класс ошибки целиком: имя ключа конфигурации не должно случайно совпасть
  # с методом коллекции. Если такой ключ отсутствует, fetch обязан вернуть
  # значение вызывающей стороны, а не внутренности Hash/Enumerable.
  def test_fetch_never_returns_a_collection_method_result_for_a_missing_key
    sentinel = Object.new
    section = { "amount" => 5 }

    %i[min max count first size sum].each do |key|
      # Проверка не тавтологична только потому, что Hash действительно
      # отвечает на каждое из этих имён.
      assert_respond_to section, key
      assert_same sentinel, RouteLens::Scoring::Support.fetch(section, key, sentinel),
                  "fetch(:#{key}) вернул значение метода коллекции вместо значения по умолчанию"
      assert_same sentinel, RouteLens::Scoring::Support.fetch({}, key, sentinel)
      assert_nil RouteLens::Scoring::Support.fetch(section, key)
    end

    # Присутствующий ключ по-прежнему читается, включая символьную форму.
    assert_equal 50_001, RouteLens::Scoring::Support.fetch({ "min" => 50_001 }, :min, sentinel)
    assert_equal 50_001, RouteLens::Scoring::Support.fetch({ min: 50_001 }, :min, sentinel)
  end

  def test_fetch_reads_symbol_and_string_keys_from_hashes_and_provider_state
    state = RouteLens::ProviderState.new(provider("vipay", conversion_24h: 0.87))

    assert_equal 0.87, RouteLens::Scoring::Support.fetch({ conversion_24h: 0.87 }, :conversion_24h)
    assert_equal 0.87, RouteLens::Scoring::Support.fetch({ "conversion_24h" => 0.87 }, :conversion_24h)
    assert_equal 0.87, RouteLens::Scoring::Support.fetch(state, :conversion_24h)
    assert_nil RouteLens::Scoring::Support.fetch(state, :missing_attribute)
  end

  def test_provider_name_resolves_for_every_supported_input
    state = RouteLens::ProviderState.new(provider("vipay"))

    assert_equal "vipay", RouteLens::Scoring::Support.provider_name(state)
    assert_equal "vipay", RouteLens::Scoring::Support.provider_name(provider("vipay"))
    assert_equal "vipay", RouteLens::Scoring::Support.provider_name(Double.new("vipay"))
    assert_equal "unknown", RouteLens::Scoring::Support.provider_name({})
  end

  def test_relative_position_reports_indistinguishable_candidates
    assert_in_delta 0.5, RouteLens::Scoring::Support.relative_position(2.0, [1.0, 3.0]), 0.0001
    assert_nil RouteLens::Scoring::Support.relative_position(2.0, [2.0, 2.0])
    assert_nil RouteLens::Scoring::Support.relative_position(2.0, [])
  end

  def test_portfolio_providers_prefers_the_full_provider_list
    all = [provider("a"), provider("b")]
    eligible = [provider("a")]

    assert_equal all, RouteLens::Scoring::Support.portfolio_providers(providers: all, eligible_providers: eligible)
    assert_equal eligible, RouteLens::Scoring::Support.portfolio_providers(eligible_providers: eligible)
    assert_empty RouteLens::Scoring::Support.portfolio_providers({})
  end
end
