require_relative "test_helper"
require "lib/wpgsa"
require "tmpdir"
require "json"
require "fileutils"

class TestJobMetadataAtomicity < Minitest::Test
  def build_job(data_dir)
    WPGSA::Job.new(
      "d5767493-4b86-4297-8b8f-d650f413d952",
      "/tmp/wpgsa/d5767493-4b86-4297-8b8f-d650f413d952",
      data_dir,
      "sample.txt",
      "net.network"
    )
  end

  # lib/wpgsa/job.rb#write_metadata is read concurrently by the Puma
  # worker, the job runner, and script/cleanup-jobs. A non-atomic
  # write (truncate then write in place) exposes a window where a reader
  # sees an empty or partial file. This drives a writer thread that keeps
  # rewriting job.json with growing payloads (to widen that window) while
  # a reader repeatedly reads the raw file and asserts it is always
  # complete, valid JSON.
  def test_write_metadata_never_leaves_a_truncated_file_for_a_concurrent_reader
    Dir.mktmpdir do |data_dir|
      job = build_job(data_dir)
      job.write_metadata("status" => "queued")

      stop = false
      writer = Thread.new do
        i = 0
        until stop
          job.write_metadata("status" => "queued", "padding" => "x" * (i % 5000))
          i += 1
        end
      end

      reader_failures = []
      200.times do
        content = File.read(job.metadata_path)
        if content.empty?
          reader_failures << "empty read"
          next
        end
        begin
          JSON.parse(content)
        rescue JSON::ParserError => e
          reader_failures << "parse error: #{e.message}"
        end
      end

      stop = true
      writer.join

      assert_empty reader_failures, "a concurrent reader must never see a truncated or empty job.json"
    end
  end

  def test_write_metadata_does_not_leave_temp_files_behind
    Dir.mktmpdir do |data_dir|
      job = build_job(data_dir)
      job.write_metadata("status" => "queued")
      job.write_metadata("status" => "running")

      assert_equal ["job.json"], Dir.children(data_dir)
    end
  end

  def test_write_metadata_round_trips_through_metadata
    Dir.mktmpdir do |data_dir|
      job = build_job(data_dir)
      job.write_metadata("status" => "running", "started_at" => "now")

      assert_equal "running", job.metadata["status"]
      assert_equal "now", job.metadata["started_at"]
    end
  end
end

# Orphan detection: lib/wpgsa/job.rb#metadata must notice a queued/
# running job whose recorded runner pid is not actually alive, and
# persist that as "failed" -- otherwise the job hangs at "running"
# forever (a dead pid, an abandoned work directory, no results, and
# nothing in the system that will ever notice), which is exactly what
# happened in production when systemd killed an in-flight analysis's
# cgroup out from under it.
class TestJobOrphanDetection < Minitest::Test
  def build_job(data_dir, uuid: "d5767493-4b86-4297-8b8f-d650f413d952")
    WPGSA::Job.new(
      uuid,
      "/tmp/wpgsa/#{uuid}",
      data_dir,
      "sample.txt",
      "net.network"
    )
  end

  def teardown
    WPGSA::Job.proc_root = "/proc"
  end

  # A pid that definitely does not belong to any live process: spawn a
  # trivial child and reap it before using its pid.
  def dead_pid
    pid = Process.spawn("true", out: File::NULL, err: File::NULL)
    Process.wait(pid)
    pid
  end

  def test_a_running_job_with_a_dead_pid_is_reported_and_persisted_as_failed
    Dir.mktmpdir do |data_dir|
      job = build_job(data_dir)
      job.write_metadata("status" => "running", "pid" => dead_pid)

      metadata = job.metadata
      assert_equal "failed", metadata["status"]
      refute_nil metadata["finished_at"]
      assert_match(/died before completing/i, metadata["error_message"])

      # The correction must be persisted -- script/cleanup-jobs treats
      # any non-terminal status as still in progress and will never
      # reclaim the directory of a job that only *looks* live on disk.
      persisted = JSON.parse(File.read(job.metadata_path))
      assert_equal "failed", persisted["status"]
      assert_match(/died before completing/i, persisted["error_message"])
    end
  end

  def test_a_queued_job_with_a_dead_pid_is_also_reported_as_failed
    Dir.mktmpdir do |data_dir|
      job = build_job(data_dir)
      job.write_metadata("status" => "queued", "pid" => dead_pid)

      assert_equal "failed", job.metadata["status"]
    end
  end

  # The concurrency cap (WPGSA::Slot) leaves a queued job's runner
  # genuinely alive, blocked inside Slot.acquire waiting for a slot. That
  # must never be flagged as orphaned -- getting this wrong would fail
  # every queued job the moment the cap is reached.
  def test_a_queued_job_with_a_live_runner_process_is_left_alone
    Dir.mktmpdir do |data_dir|
      job = build_job(data_dir)
      runner = Process.spawn("sleep", "5", out: File::NULL, err: File::NULL)
      begin
        job.write_metadata("status" => "queued", "pid" => runner)

        metadata = job.metadata
        assert_equal "queued", metadata["status"]
        assert_nil metadata["finished_at"]
        assert_nil metadata["error_message"]
      ensure
        Process.kill("TERM", runner)
        Process.wait(runner)
      end
    end
  end

  def test_a_running_job_with_a_live_runner_process_is_left_alone
    Dir.mktmpdir do |data_dir|
      job = build_job(data_dir)
      runner = Process.spawn("sleep", "5", out: File::NULL, err: File::NULL)
      begin
        job.write_metadata("status" => "running", "pid" => runner)
        assert_equal "running", job.metadata["status"]
      ensure
        Process.kill("TERM", runner)
        Process.wait(runner)
      end
    end
  end

  def test_a_finished_job_is_never_touched_even_with_a_dead_pid
    Dir.mktmpdir do |data_dir|
      job = build_job(data_dir)
      job.write_metadata(
        "status" => "finished",
        "pid" => dead_pid,
        "finished_at" => "2026-01-01T00:00:00Z",
        "result_paths" => ["public/data/x/result.tsv"]
      )

      metadata = job.metadata
      assert_equal "finished", metadata["status"]
      assert_equal "2026-01-01T00:00:00Z", metadata["finished_at"]
      assert_equal ["public/data/x/result.tsv"], metadata["result_paths"]
    end
  end

  def test_a_failed_job_is_never_touched_even_with_a_dead_pid
    Dir.mktmpdir do |data_dir|
      job = build_job(data_dir)
      job.write_metadata(
        "status" => "failed",
        "pid" => dead_pid,
        "finished_at" => "2026-01-01T00:00:00Z",
        "error_message" => "the container exited non-zero"
      )

      metadata = job.metadata
      assert_equal "failed", metadata["status"]
      assert_equal "the container exited non-zero", metadata["error_message"]
    end
  end

  def test_a_queued_job_with_no_recorded_pid_yet_is_not_flagged
    Dir.mktmpdir do |data_dir|
      job = build_job(data_dir)
      job.write_metadata("status" => "queued")

      assert_equal "queued", job.metadata["status"]
    end
  end

  # --- /proc cmdline matching (the Linux production path) ---
  #
  # The development machine is macOS, which has no /proc at all, so
  # runner_alive? falls back to a plain signal check there (exercised by
  # the tests above, against real spawned processes). To exercise the
  # /proc-based cmdline match that guards against pid reuse on the
  # platform these jobs actually run on, WPGSA::Job.proc_root is
  # injectable; point it at a fabricated directory laid out the way the
  # kernel would lay out /proc.

  def write_fake_cmdline(proc_root, pid, argv)
    dir = File.join(proc_root, pid.to_s)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "cmdline"), "#{argv.join("\0")}\0")
  end

  def test_proc_cmdline_matching_this_runner_is_not_orphaned
    Dir.mktmpdir do |data_dir|
      Dir.mktmpdir do |proc_root|
        WPGSA::Job.proc_root = proc_root
        uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        job = build_job(data_dir, uuid: uuid)
        pid = 424_242
        write_fake_cmdline(proc_root, pid, ["/usr/bin/ruby", "/opt/wpgsa/script/run-job", uuid])

        job.write_metadata("status" => "running", "pid" => pid)
        assert_equal "running", job.metadata["status"]
      end
    end
  end

  # This is the pid-reuse scenario itself: the pid is "alive" (its
  # cmdline file exists) but belongs to a completely different process,
  # not this job's runner.
  def test_proc_cmdline_belonging_to_a_different_process_is_orphaned
    Dir.mktmpdir do |data_dir|
      Dir.mktmpdir do |proc_root|
        WPGSA::Job.proc_root = proc_root
        job = build_job(data_dir)
        pid = 424_243
        write_fake_cmdline(proc_root, pid, ["/usr/bin/vim", "notes.txt"])

        job.write_metadata("status" => "running", "pid" => pid)
        assert_equal "failed", job.metadata["status"]
      end
    end
  end

  # Same pid reuse hazard, but the reused process happens to be another
  # job's runner rather than something unrelated -- still not this job's
  # runner.
  def test_proc_cmdline_belonging_to_a_different_jobs_runner_is_orphaned
    Dir.mktmpdir do |data_dir|
      Dir.mktmpdir do |proc_root|
        WPGSA::Job.proc_root = proc_root
        job = build_job(data_dir, uuid: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        pid = 424_244
        write_fake_cmdline(proc_root, pid, [
                             "/usr/bin/ruby", "/opt/wpgsa/script/run-job",
                             "ffffffff-ffff-ffff-ffff-ffffffffffff"
                           ])

        job.write_metadata("status" => "running", "pid" => pid)
        assert_equal "failed", job.metadata["status"]
      end
    end
  end

  def test_proc_missing_cmdline_file_is_orphaned
    Dir.mktmpdir do |data_dir|
      Dir.mktmpdir do |proc_root|
        WPGSA::Job.proc_root = proc_root
        job = build_job(data_dir)
        job.write_metadata("status" => "running", "pid" => 424_245)
        # No cmdline file written at all for this pid -- the process is
        # simply gone, as if it had already exited.

        assert_equal "failed", job.metadata["status"]
      end
    end
  end
end
