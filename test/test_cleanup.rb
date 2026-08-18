require_relative "test_helper"
require "tmpdir"
require "fileutils"
require "json"
require "open3"

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

  def write_status(path, status)
    File.write(File.join(path, "job.json"), JSON.generate("status" => status))
  end

  def set_age(path, age_days)
    t = Time.now - age_days * 86_400
    File.utime(t, t, path)
  end

  def running_as_root?
    Process.uid.zero?
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

  def run_cleanup_capturing_output(data_dir, workdir, days)
    Open3.capture3(
      { "WPGSA_DATA_DIR" => data_dir,
        "WPGSA_WORKDIR" => workdir,
        "WPGSA_RETENTION_DAYS" => days.to_s },
      RbConfig.ruby, SCRIPT
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

  def test_a_failed_removal_is_not_counted_and_is_reported
    skip "root bypasses the write-permission denial this test relies on" if running_as_root?

    Dir.mktmpdir do |data_dir|
      Dir.mktmpdir do |workdir|
        old = make_dir(data_dir, "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", 40)
        File.chmod(0o555, data_dir)
        begin
          stdout, stderr, status = run_cleanup_capturing_output(data_dir, workdir, 30)
          refute status.success?, "script should exit non-zero when a removal fails"
          assert File.exist?(old), "a directory that failed to be removed must not vanish from the report"
          assert_includes stdout, "removed 0", "a failed removal must not be counted as removed"
          assert_includes stderr, old, "the failing path must be named in the failure output"
        ensure
          File.chmod(0o755, data_dir)
        end
      end
    end
  end

  def test_keeps_a_running_job_past_the_retention_window
    Dir.mktmpdir do |data_dir|
      Dir.mktmpdir do |workdir|
        running = make_dir(data_dir, "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", 40)
        write_status(running, "running")
        assert run_cleanup(data_dir, workdir, 30)
        assert File.exist?(running), "a running job must not be swept"
      end
    end
  end

  def test_keeps_a_queued_job_past_the_retention_window
    Dir.mktmpdir do |data_dir|
      Dir.mktmpdir do |workdir|
        queued = make_dir(data_dir, "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", 40)
        write_status(queued, "queued")
        assert run_cleanup(data_dir, workdir, 30)
        assert File.exist?(queued), "a queued job must not be swept"
      end
    end
  end

  def test_removes_a_finished_job_older_than_the_retention_period
    Dir.mktmpdir do |data_dir|
      Dir.mktmpdir do |workdir|
        finished = make_dir(data_dir, "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", 40)
        write_status(finished, "finished")
        assert run_cleanup(data_dir, workdir, 30)
        refute File.exist?(finished)
      end
    end
  end

  def test_removes_a_failed_job_older_than_the_retention_period
    Dir.mktmpdir do |data_dir|
      Dir.mktmpdir do |workdir|
        failed = make_dir(data_dir, "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", 40)
        write_status(failed, "failed")
        assert run_cleanup(data_dir, workdir, 30)
        refute File.exist?(failed)
      end
    end
  end

  def test_removes_a_directory_with_no_job_json_when_old
    Dir.mktmpdir do |data_dir|
      Dir.mktmpdir do |workdir|
        old = make_dir(data_dir, "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", 40)
        File.delete(File.join(old, "job.json"))
        # Deleting a directory entry bumps the parent directory's mtime, so
        # re-age it after removing job.json to keep this a genuine "old
        # directory with no job.json" fixture rather than a fresh one.
        set_age(old, 40)
        assert run_cleanup(data_dir, workdir, 30)
        refute File.exist?(old)
      end
    end
  end

  def test_removes_a_directory_with_corrupt_job_json_when_old
    Dir.mktmpdir do |data_dir|
      Dir.mktmpdir do |workdir|
        old = make_dir(data_dir, "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", 40)
        File.write(File.join(old, "job.json"), "{not valid json")
        assert run_cleanup(data_dir, workdir, 30)
        refute File.exist?(old)
      end
    end
  end

  def test_removes_a_directory_with_an_unreadable_job_json_and_keeps_sweeping
    skip "root bypasses the read-permission denial this test relies on" if running_as_root?

    Dir.mktmpdir do |data_dir|
      Dir.mktmpdir do |workdir|
        broken = make_dir(data_dir, "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", 40)
        File.chmod(0o000, File.join(broken, "job.json"))
        other = make_dir(data_dir, "ffffffff-1111-2222-3333-444444444444", 40)
        work_old = make_dir(workdir, "55555555-6666-7777-8888-999999999999", 40)

        begin
          assert run_cleanup(data_dir, workdir, 30)
        ensure
          job_json = File.join(broken, "job.json")
          File.chmod(0o644, job_json) if File.exist?(job_json)
        end

        refute File.exist?(broken), "an old directory with an unreadable job.json must still be removed"
        refute File.exist?(other), "an unreadable entry must not stop the rest of its own root from being swept"
        refute File.exist?(work_old), "an unreadable entry in the data dir must not stop the work dir from being swept"
      end
    end
  end

  def test_removes_a_directory_whose_job_json_is_a_directory_and_keeps_sweeping
    Dir.mktmpdir do |data_dir|
      Dir.mktmpdir do |workdir|
        broken = make_dir(data_dir, "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", 40)
        File.delete(File.join(broken, "job.json"))
        FileUtils.mkdir_p(File.join(broken, "job.json"))
        # Both the delete and the mkdir_p above are directory-entry
        # mutations of `broken`, so re-age it the same way the missing-
        # job.json test does.
        set_age(broken, 40)
        other = make_dir(data_dir, "ffffffff-1111-2222-3333-444444444444", 40)
        work_old = make_dir(workdir, "55555555-6666-7777-8888-999999999999", 40)

        assert run_cleanup(data_dir, workdir, 30)

        refute File.exist?(broken), "an old directory whose job.json is itself a directory must still be removed"
        refute File.exist?(other), "a broken entry must not stop the rest of its own root from being swept"
        refute File.exist?(work_old), "a broken entry in the data dir must not stop the work dir from being swept"
      end
    end
  end
end
