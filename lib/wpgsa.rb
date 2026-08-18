require 'wpgsa/docker'
require 'wpgsa/job'
require 'wpgsa/result'

module WPGSA
  class InvalidDataId < StandardError; end
  class AnalysisFailed < StandardError; end

  UUID_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  EXAMPLE_ID = "example".freeze

  def self.valid_data_id?(id)
    return false unless id.is_a?(String)
    return true if id == EXAMPLE_ID

    UUID_PATTERN.match?(id)
  end

  def self.validate_data_id!(id)
    raise InvalidDataId, "invalid data id" unless valid_data_id?(id)

    id
  end
end
