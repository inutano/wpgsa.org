require_relative "test_helper"
require "lib/wpgsa"
require "fileutils"

class TestResultInputData < Minitest::Test
  VALID_UUID = "d5767493-4b86-4297-8b8f-d650f413d952"

  def data_dir
    File.join(APP_ROOT, "public", "data", VALID_UUID)
  end

  def setup
    FileUtils.mkdir_p(data_dir)
  end

  def teardown
    FileUtils.rm_rf(data_dir)
  end

  # Finding 10: job.json and job.log live alongside the result files (see
  # lib/wpgsa/job.rb) and both sort ahead of a typical uploaded filename,
  # so without excluding them, Result#input_data resolves to "job.json" for
  # every real job.
  def test_input_data_excludes_job_metadata_files
    File.write(File.join(data_dir, "job.json"), "{}")
    File.write(File.join(data_dir, "job.log"), "log output")
    File.write(File.join(data_dir, "sample.txt"), "a\tb\tc\n")

    result = WPGSA::Result.new(VALID_UUID, "input")
    assert_equal File.expand_path(File.join(data_dir, "sample.txt")), File.expand_path(result.input_data)
  end

  def test_input_data_still_excludes_known_result_files
    File.write(File.join(data_dir, "job.json"), "{}")
    File.write(File.join(data_dir, "job.log"), "log output")
    File.write(File.join(data_dir, "sample.txt"), "a\tb\tc\n")
    File.write(File.join(data_dir, "p_value.txt"), "p\n")
    File.write(File.join(data_dir, "q_value.txt"), "q\n")
    File.write(File.join(data_dir, "t_score.txt"), "t\n")

    result = WPGSA::Result.new(VALID_UUID, "input")
    assert_equal File.expand_path(File.join(data_dir, "sample.txt")), File.expand_path(result.input_data)
  end

  def test_result_file_path_for_input_type_resolves_to_the_uploaded_file
    File.write(File.join(data_dir, "job.json"), "{}")
    File.write(File.join(data_dir, "sample.txt"), "a\tb\tc\n")

    result = WPGSA::Result.new(VALID_UUID, "input")
    assert_equal File.expand_path(File.join(data_dir, "sample.txt")), File.expand_path(result.result_file_path)
  end
end
