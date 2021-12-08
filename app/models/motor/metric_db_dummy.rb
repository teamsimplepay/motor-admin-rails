# frozen_string_literal: true

# This exists purely as a simple way to get a connection to the DB that stores our metrics,
# (hardcoded for our purposes, may make configurable)
module Motor
  class MetricDbDummy < ActiveRecord::Base
    connects_to database: { writing: :main_metrics, reading: :main_metrics }
  end
end
