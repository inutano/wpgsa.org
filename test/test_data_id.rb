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

  def test_data_dir_resolves_a_valid_uuid_inside_the_root
    path = WPGSA.data_dir(VALID)
    assert_equal File.join(WPGSA::DATA_ROOT, VALID), path
    assert WPGSA.path_within_root?(path, WPGSA::DATA_ROOT)
  end

  def test_data_dir_resolves_the_example_id_inside_the_root
    path = WPGSA.data_dir(WPGSA::EXAMPLE_ID)
    assert_equal File.join(WPGSA::DATA_ROOT, WPGSA::EXAMPLE_ID), path
    assert WPGSA.path_within_root?(path, WPGSA::DATA_ROOT)
  end

  def test_data_dir_raises_on_parent_directory_traversal
    assert_raises(WPGSA::InvalidDataId) { WPGSA.data_dir("../../etc") }
  end

  def test_data_dir_raises_on_an_absolute_path_id
    assert_raises(WPGSA::InvalidDataId) { WPGSA.data_dir("/etc/passwd") }
  end

  # This documents the exact defect the containment check guards against:
  # a naive `path.start_with?(root)` (no separator) would let a sibling
  # directory whose name merely starts with the root's name -- "data" vs
  # "data-evil" -- pass as "contained." Comparing against `root +
  # File::SEPARATOR` instead is what data_dir relies on, and what CodeQL's
  # rb/path-injection query recognises as sound. valid_data_id!'s regex
  # already blocks any id containing a path separator, so this exercises
  # path_within_root? directly rather than routing an id through data_dir.
  def test_path_within_root_rejects_a_sibling_directory_sharing_a_name_prefix
    root = File.join(WPGSA::DATA_ROOT)
    sibling = "#{root}-evil/x"
    refute WPGSA.path_within_root?(sibling, root)
  end

  def test_path_within_root_accepts_a_real_child_path
    root = WPGSA::DATA_ROOT
    child = File.join(root, "abc")
    assert WPGSA.path_within_root?(child, root)
  end
end
