# frozen_string_literal: true

require "date"
require "yaml"

module RouteLens
  class ConfigError < StandardError; end

  # Загружает policy через safe_load без YAML aliases и произвольных классов.
  class ConfigLoader
    def self.load(path)
      data = YAML.safe_load_file(path, permitted_classes: [Date, Time], aliases: false)
      raise ConfigError, "Policy configuration must be an object" unless data.is_a?(Hash)

      data
    rescue Errno::ENOENT
      raise ConfigError, "Policy configuration not found: #{path}"
    rescue Psych::Exception => e
      raise ConfigError, "Invalid policy YAML in #{path}: #{e.message}"
    end
  end
end
