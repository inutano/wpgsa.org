require_relative "test_helper"
require "lib/wpgsa"

class TestDataId < Minitest::Test
  VALID = "d5767493-4b86-4297-8b8f-d650f413d952"

  def test_accepts_a_uuid
    assert WPGSA.valid_data_id?(VALID)
  end

  def test_accepts_the_example_id
    assert WPGSA.valid_data_id?("example")
  end

  def test_rejects_nil
    refute WPGSA.valid_data_id?(nil)
  end

  def test_rejects_empty_string
    refute WPGSA.valid_data_id?("")
  end

  def test_rejects_parent_directory_traversal
    refute WPGSA.valid_data_id?("../../etc")
  end

  def test_rejects_a_uuid_with_a_traversal_suffix
    refute WPGSA.valid_data_id?("#{VALID}/../../etc")
  end

  def test_rejects_uppercase_uuid
    refute WPGSA.valid_data_id?(VALID.upcase)
  end

  def test_rejects_a_uuid_with_a_trailing_newline
    refute WPGSA.valid_data_id?("#{VALID}\n")
  end

  def test_job_load_raises_on_an_invalid_id
    assert_raises(WPGSA::InvalidDataId) { WPGSA::Job.load("../../etc") }
  end

  def test_result_new_raises_on_an_invalid_id
    assert_raises(WPGSA::InvalidDataId) { WPGSA::Result.new("../../etc", "p-value") }
  end
end
