require_relative "test_helper"
require "lib/wpgsa"
require "tmpdir"
require "json"

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
