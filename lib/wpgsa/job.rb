require 'json'
require 'fileutils'
require 'rbconfig'
require 'time'

module WPGSA
  class Job
    attr_reader :uuid

    def self.create(input_file, workdir, network_file_path)
      docker = WPGSA::Docker.new(input_file, workdir, network_file_path)
      job = new(
        docker.uuid,
        docker.workdir,
        docker.datadir,
        docker.input_data,
        docker.network_file
      )
      job.write_metadata(
        "status" => "queued",
        "input_filename" => docker.input_data,
        "result_paths" => []
      )
      job
    end

    def self.load(uuid)
      WPGSA.validate_data_id!(uuid)
      data_dir = File.join(__dir__, "../../public/data", uuid)
      metadata = JSON.parse(File.read(File.join(data_dir, "job.json")))
      new(
        metadata["uuid"],
        metadata["workdir"],
        metadata["data_dir"],
        metadata["input_filename"],
        metadata["network_file"]
      )
    end

    def initialize(uuid, workdir, data_dir, input_filename, network_file)
      @uuid = uuid
      @workdir = workdir
      @data_dir = data_dir
      @input_filename = input_filename
      @network_file = network_file
    end

    def metadata_path
      File.join(@data_dir, "job.json")
    end

    def metadata
      JSON.parse(File.read(metadata_path))
    rescue Errno::ENOENT
      {
        "uuid" => @uuid,
        "status" => "unknown"
      }
    end

    def spawn!
      pid = Process.spawn(
        RbConfig.ruby,
        File.join(__dir__, "../../script/run-job"),
        @uuid,
        chdir: File.join(__dir__, "../.."),
        out: metadata_log_path,
        err: metadata_log_path
      )
      Process.detach(pid)
      write_metadata("pid" => pid)
      pid
    end

    def run!(concurrency: 2)
      WPGSA::Slot.acquire(concurrency) do
        write_metadata(
          "status" => "running",
          "started_at" => timestamp,
          "error_message" => nil
        )

        docker = WPGSA::Docker.from_job(
          @uuid,
          @workdir,
          @data_dir,
          @input_filename,
          @network_file
        )

        result_paths = docker.run_analysis
        write_metadata(
          "status" => "finished",
          "finished_at" => timestamp,
          "result_paths" => result_paths
        )
      end
    rescue StandardError => e
      write_metadata(
        "status" => "failed",
        "finished_at" => timestamp,
        "error_message" => e.message,
        "result_paths" => []
      )
      raise
    end

    def result_ready?
      metadata["status"] == "finished"
    end

    def write_metadata(attrs)
      current = metadata_base.merge(metadata)
      updated = current.merge(attrs)
      FileUtils.mkdir_p(@data_dir)

      # The Puma worker, the runner, and script/cleanup-jobs all read
      # job.json concurrently. Writing in place (truncate then write) leaves
      # a window where a reader sees a truncated/empty file. Write to a
      # temp file in the same directory and rename onto the target instead:
      # rename is atomic within a directory, so readers only ever see the
      # old complete file or the new complete file, never a partial one.
      tmp_path = "#{metadata_path}.tmp.#{Process.pid}.#{object_id}"
      File.open(tmp_path, "w") do |f|
        f.write(JSON.pretty_generate(updated))
      end
      File.rename(tmp_path, metadata_path)

      updated
    end

    def metadata_log_path
      File.join(@data_dir, "job.log")
    end

    private

    def metadata_base
      {
        "uuid" => @uuid,
        "status" => "queued",
        "workdir" => @workdir,
        "data_dir" => @data_dir,
        "input_filename" => @input_filename,
        "network_file" => @network_file,
        "created_at" => timestamp,
        "started_at" => nil,
        "finished_at" => nil,
        "error_message" => nil,
        "result_paths" => []
      }
    end

    def timestamp
      Time.now.utc.iso8601
    end
  end
end
