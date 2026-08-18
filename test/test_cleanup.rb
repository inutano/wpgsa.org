require_relative "test_helper"
require "tmpdir"
require "fileutils"

class TestCleanupJobs < Minitest::Test
  SCRIPT = File.join(APP_ROOT, "script", "cleanup-jobs")

  def make_dir(root, name, age_days)
    path = File.join(root, name)
    FileUtils.mkdir_p(path)
    File.write(File.join(path, "job.json"), "{}")
    t = Time.now - age_days * 86_400
    File.utime(t, t, path)
    path
  end

  def run_cleanup(data_dir, workdir, days)
    system(
      { "WPGSA_DATA_DIR" => data_dir,
        "WPGSA_WORKDIR" => workdir,
        "WPGSA_RETENTION_DAYS" => days.to_s },
      RbConfig.ruby, SCRIPT,
      out: File::NULL
    )
  end

  def test_removes_directories_older_than_the_retention_period
    Dir.mktmpdir do |data_dir|
      Dir.mktmpdir do |workdir|
        old = make_dir(data_dir, "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", 40)
        assert run_cleanup(data_dir, workdir, 30)
        refute File.exist?(old)
      end
    end
  end

  def test_keeps_directories_inside_the_retention_period
    Dir.mktmpdir do |data_dir|
      Dir.mktmpdir do |workdir|
        fresh = make_dir(data_dir, "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", 3)
        assert run_cleanup(data_dir, workdir, 30)
        assert File.exist?(fresh)
      end
    end
  end

  def test_never_removes_the_example_directory
    Dir.mktmpdir do |data_dir|
      Dir.mktmpdir do |workdir|
        example = make_dir(data_dir, "example", 4000)
        assert run_cleanup(data_dir, workdir, 30)
        assert File.exist?(example), "example must survive cleanup"
      end
    end
  end

  def test_cleans_the_work_directory_too
    Dir.mktmpdir do |data_dir|
      Dir.mktmpdir do |workdir|
        old = make_dir(workdir, "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", 40)
        assert run_cleanup(data_dir, workdir, 30)
        refute File.exist?(old)
      end
    end
  end
end
