# frozen_string_literal: true

require_relative "../test_helper"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require "yaml"

# bin/compare_policies обязан играть очередь на том же снимке провайдеров,
# что и bin/route. Он загружал providers.json без секции provider_overrides,
# поэтому сценарии сравнения молча работали с другими параметрами правил, и
# «разница между политиками» частично объяснялась разными входными данными.
class ComparePoliciesIntegrationTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def test_provider_overrides_from_the_policy_file_reach_the_compared_scenarios
    Dir.mktmpdir("route-lens-compare") do |directory|
      policy = File.join(directory, "policy.yml")
      output = File.join(directory, "comparison.json")
      # Лимит в один запрос в минуту достижим на публичной очереди: op_103 и
      # op_104 попадают в одну минуту и оба уходят на quickpay. Со включённым
      # переопределением второй операции остаётся только внутренний провайдер.
      File.write(policy, strict_policy_config.to_yaml)

      stdout, stderr, status = run_comparison(policy, output)

      assert status.success?, "bin/compare_policies завершился с ошибкой: #{stderr}"
      assert_includes stdout, "Wrote"
      selections = JSON.parse(File.read(output)).fetch("scenarios").first.fetch("selections")

      assert_equal "quickpay", selections.fetch("op_103")
      assert_equal "spacepayments", selections.fetch("op_104"),
                   "provider_overrides не применены: op_104 всё ещё уходит на quickpay"
    end
  end

  # Ранняя ошибка входа маскировалась блоком ensure: Ruby считает локальную
  # переменную определённой с момента разбора, поэтому File.exist?(nil)
  # подменял настоящую причину на TypeError, а код возврата оставался 0.
  def test_unreadable_policy_file_reports_the_real_cause_and_fails_loudly
    Dir.mktmpdir("route-lens-compare") do |directory|
      output = File.join(directory, "comparison.json")

      _stdout, stderr, status = run_comparison(File.join(directory, "missing.yml"), output)

      refute status.success?
      assert_includes stderr, "Policy configuration not found"
      refute_includes stderr, "TypeError"
      refute_path_exists output
    end
  end

  private

  def strict_policy_config
    config = YAML.safe_load_file(File.join(ROOT, "config/routing.yml"))
    config.merge("provider_overrides" => { "quickpay" => { "requests_per_minute_limit" => 1 } })
  end

  def run_comparison(policy, output)
    Open3.capture3(
      RbConfig.ruby,
      File.join(ROOT, "bin/compare_policies"),
      "--policy", policy,
      "--output", output,
      chdir: ROOT
    )
  end
end
