# frozen_string_literal: true

module Motor
  class Config < ::Motor::ApplicationRecord
    self.table_name = "motor.configs"
    audited

    serialize :value, HashSerializer
  end
end
