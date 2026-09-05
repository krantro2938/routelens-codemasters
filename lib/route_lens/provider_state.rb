# frozen_string_literal: true

require "thread"
require "time"

module RouteLens
  class StateError < StandardError; end
  class CapacityExceeded < StateError; end
  class UnknownReservation < StateError; end

  # Изменяемое потокобезопасное состояние одного провайдера. Атрибуты копируются,
  # поэтому маршрутизация никогда не меняет исходный JSON-документ.
  class ProviderState
    SELF_PROVIDER = "spacepayments"

    attr_reader :payment_system

    def initialize(attributes)
      raise ArgumentError, "provider attributes must be a Hash" unless attributes.is_a?(Hash)

      @attributes = deep_copy(attributes.transform_keys(&:to_s))
      @payment_system = @attributes.fetch("payment_system")
      @mutex = Mutex.new
      @reservations = {}
      @request_bucket = nil
      @recorded_requests = 0
    end

    alias name payment_system

    def [](key)
      @mutex.synchronize { deep_copy(@attributes[key.to_s]) }
    end

    def key?(key)
      @mutex.synchronize { @attributes.key?(key.to_s) }
    end

    def fetch(key, *default, &block)
      @mutex.synchronize { deep_copy(@attributes.fetch(key.to_s, *default, &block)) }
    end

    def active?
      self["status"] == "active"
    end

    def self_provider?
      payment_system == SELF_PROVIDER || self["self_provider"] == true
    end

    def to_h
      @mutex.synchronize { deep_copy(@attributes) }
    end

    alias snapshot to_h

    # Атомарно резервирует in-progress ёмкость и реквизит. reservation_id связывает
    # последующий расчёт с конкретной попыткой и защищает от двойного освобождения.
    def reserve!(amount, reservation_id: nil, at: Time.now, record_request: true)
      amount = positive_number!(amount)
      @mutex.synchronize do
        if reservation_id && @reservations.key?(reservation_id.to_s)
          raise StateError, "reservation #{reservation_id} already exists for #{payment_system}"
        end

        assert_capacity!(amount)
        assert_request_capacity!(at) if record_request
        increment!("in_progress_count", 1)
        increment!("in_progress_amount", amount)
        decrement!("available_requisites", 1) if @attributes.key?("available_requisites")
        record_request_unlocked(at) if record_request
        @reservations[reservation_id.to_s] = amount if reservation_id
      end
      self
    end

    # Одобрение освобождает временный резерв и добавляет сумму в дневной оборот.
    def approve!(amount = nil, reservation_id: nil)
      settle!("approved", amount, reservation_id: reservation_id)
    end

    def reject!(amount = nil, reservation_id: nil)
      settle!("rejected", amount, reservation_id: reservation_id)
    end

    def expire!(amount = nil, reservation_id: nil)
      settle!("expired", amount, reservation_id: reservation_id)
    end

    def release!(amount = nil, reservation_id: nil)
      settle!("released", amount, reservation_id: reservation_id)
    end

    def settle!(result, amount = nil, reservation_id: nil)
      unless %w[approved rejected expired released].include?(result.to_s)
        raise ArgumentError, "unknown settlement result: #{result}"
      end

      @mutex.synchronize do
        # Все связанные счётчики меняются в одной критической секции, чтобы
        # другой поток не увидел частично рассчитанный резерв.
        resolved_amount = reservation_amount!(amount, reservation_id)
        decrement!("in_progress_count", 1)
        decrement!("in_progress_amount", resolved_amount)
        increment!("available_requisites", 1) if @attributes.key?("available_requisites")
        increment!("daily_approved_amount", resolved_amount) if result.to_s == "approved"
        @reservations.delete(reservation_id.to_s) if reservation_id
      end
      self
    end

    # Записывает попытку в минутное окно, используемое ограничением RPM.
    def record_request!(at: Time.now)
      @mutex.synchronize { record_request_unlocked(at) }
      self
    end

    def requests_per_minute(at: Time.now)
      @mutex.synchronize { request_count_unlocked(at) }
    end

    private

    def reservation_amount!(amount, reservation_id)
      if reservation_id
        stored = @reservations[reservation_id.to_s]
        raise UnknownReservation, "unknown reservation #{reservation_id} for #{payment_system}" unless stored
        if amount && Float(amount) != stored
          raise StateError, "reservation amount mismatch for #{reservation_id}"
        end
        stored
      elsif amount
        positive_number!(amount)
      else
        raise ArgumentError, "amount or reservation_id is required"
      end
    end

    def assert_capacity!(amount)
      prospective_count = numeric_attribute("in_progress_count").to_i + 1
      prospective_amount = numeric_attribute("in_progress_amount") + amount
      approved_amount = numeric_attribute("daily_approved_amount")

      assert_at_most!(prospective_count, @attributes["in_progress_count_limit"], "in-progress count")
      assert_at_most!(prospective_amount, @attributes["in_progress_amount_limit"], "in-progress amount")
      assert_at_most!(approved_amount + amount, @attributes["daily_amount_limit"], "daily amount")
      if @attributes.key?("available_requisites") && numeric_attribute("available_requisites") < 1
        raise CapacityExceeded, "#{payment_system} has no available requisites"
      end
    end

    def assert_request_capacity!(at)
      limit = @attributes["requests_per_minute_limit"]
      return if limit.nil?

      prospective = request_count_unlocked(at) + 1
      assert_at_most!(prospective, limit, "requests-per-minute")
    end

    def assert_at_most!(value, limit, label)
      return if limit.nil? || value <= Float(limit)

      raise CapacityExceeded, "#{payment_system} #{label} limit exceeded: #{value} > #{limit}"
    end

    def increment!(field, amount)
      current = numeric_attribute(field)
      @attributes[field] = preserve_number_type(current + amount)
    end

    def decrement!(field, amount)
      current = numeric_attribute(field)
      result = current - amount
      raise StateError, "#{payment_system} #{field} cannot become negative" if result.negative?

      @attributes[field] = preserve_number_type(result)
    end

    def numeric_attribute(*fields)
      value = fields.filter_map { |field| @attributes[field] }.first
      value.nil? ? 0.0 : Float(value)
    end

    def positive_number!(value)
      number = Float(value)
      raise ArgumentError, "amount must be positive" unless number.finite? && number.positive?

      number
    rescue TypeError
      raise ArgumentError, "amount must be a finite number"
    end

    def preserve_number_type(number)
      number == number.to_i ? number.to_i : number
    end

    def minute_bucket(value)
      time = value.is_a?(Time) ? value : Time.iso8601(value.to_s)
      time.to_i / 60
    end

    def record_request_unlocked(at)
      bucket = minute_bucket(at)
      if @request_bucket != bucket
        @request_bucket = bucket
        @recorded_requests = 0
      end
      @recorded_requests += 1
    end

    def request_count_unlocked(at)
      bucket = minute_bucket(at)
      # Снимок может уже содержать внешнее значение RPM; локальные запросы
      # текущего запуска добавляются к нему только внутри той же минуты.
      baseline = numeric_attribute("requests_last_minute", "current_requests_per_minute").to_i
      baseline + (@request_bucket == bucket ? @recorded_requests : 0)
    end

    def deep_copy(value)
      Marshal.load(Marshal.dump(value))
    end
  end
end
