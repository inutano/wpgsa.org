require 'json'
require 'fileutils'
require 'rbconfig'
require 'time'

module WPGSA
  class Job
    attr_reader :uuid

    # Directory used to look for /<pid>/cmdline when deciding whether a
    # recorded pid still belongs to one of our runners. Real production
    # code always sees "/proc" (Linux); tests point this at a fabricated
    # directory so the cmdline-matching branch can be exercised on a
    # development machine (macOS) that has no /proc at all.
    class << self
      attr_accessor :proc_root
    end
    self.proc_root = "/proc"

    NON_TERMINAL_STATUSES = %w[queued running].freeze

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
      data_dir = WPGSA.data_dir(uuid)
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

    # The public read path. Unlike raw_metadata, this also detects and
    # persists an orphaned job (see orphaned? below) so that every reader
    # -- including GET /wpgsa/job, which the browser polls -- sees the
    # corrected status rather than a job stuck at "queued"/"running"
    # forever because the process that was supposed to finish it is gone.
    def metadata
      correct_orphan(raw_metadata)
    end

    def spawn!
      # script/run-job writes job.log itself, through WPGSA::LogFilter,
      # rather than having its raw stdout/stderr redirected straight to
      # the file here: the wpgsa container's stdout is a carriage-return
      # progress bar, and redirecting it unfiltered is how a real job
      # produced a 276,883-byte job.log containing 6,454 progress updates
      # and not one line of anything else.
      pid = Process.spawn(
        RbConfig.ruby,
        File.join(__dir__, "../../script/run-job"),
        @uuid,
        chdir: File.join(__dir__, "../.."),
        out: File::NULL,
        err: File::NULL
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
      current = metadata_base.merge(raw_metadata)
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

    # The raw persisted state, with no orphan correction applied. Used
    # internally by write_metadata (which must never trigger the
    # correct_orphan -> write_metadata recursion that calling the public
    # #metadata here would cause) and by #metadata itself as the value to
    # correct.
    def raw_metadata
      JSON.parse(File.read(metadata_path))
    rescue Errno::ENOENT
      {
        "uuid" => @uuid,
        "status" => "unknown"
      }
    end

    # A job is orphaned when its metadata still claims it is in flight
    # (queued -- possibly still waiting on a concurrency slot -- or
    # running) but the pid recorded for its runner is not, in fact, a
    # live instance of script/run-job for this job. That can happen
    # without any bug elsewhere: an OOM kill, an operator killing the
    # process, a host reboot. Left alone the job would stay "running"
    # forever, the retention sweep would never reclaim it (script/
    # cleanup-jobs treats any non-terminal status as still in progress),
    # and the browser would just poll until it hits its own 30-minute
    # timeout without ever being told the analysis actually died.
    def orphaned?(data)
      return false unless NON_TERMINAL_STATUSES.include?(data["status"])

      pid = data["pid"]
      return false unless pid.is_a?(Integer) && pid.positive?

      !runner_alive?(pid)
    end

    def correct_orphan(data)
      return data unless orphaned?(data)

      write_metadata(
        "status" => "failed",
        "finished_at" => timestamp,
        "error_message" => "The analysis process died before completing."
      )
    end

    # Whether `pid` is a live instance of THIS job's runner.
    #
    # A bare Process.kill(0, pid) is not enough on its own: pids get
    # reused, so a dead runner's pid can, by the time we check, belong to
    # some unrelated process that happens to be alive right now --
    # reporting that as "still running" would leave the job hung exactly
    # as before. Where /proc/<pid>/cmdline is readable we use it to
    # confirm the live process is actually this project's run-job script
    # for this uuid; an unreadable or non-matching cmdline is treated as
    # "not our process," full stop, even though the pid itself is alive.
    #
    # /proc is Linux-only. The development machine (macOS) has no /proc
    # at all, so there is nothing to read a cmdline from -- on a platform
    # without a /proc directory we fall back to the plain signal check.
    # That fallback is weaker (it can't rule out pid reuse), but it is the
    # best information available on that platform, and it is only ever
    # used when /proc itself does not exist, not merely when one pid's
    # cmdline happens to be unreadable.
    def runner_alive?(pid)
      if File.directory?(self.class.proc_root)
        runner_cmdline_matches?(pid)
      else
        process_running?(pid)
      end
    end

    def runner_cmdline_matches?(pid)
      cmdline = File.read(File.join(self.class.proc_root, pid.to_s, "cmdline"))
      return false if cmdline.empty?

      parts = cmdline.split("\0")
      parts.any? { |part| part.end_with?("script/run-job") } && parts.include?(@uuid)
    rescue SystemCallError
      # Missing (process is gone), a permission error, or any other
      # errno reading the pseudo-file -- none of that means "alive."
      false
    end

    def process_running?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      # The process exists but is owned by someone else. That is not
      # proof it is our runner, but it is proof *something* is alive at
      # that pid, which is all the signal-only fallback can tell us.
      true
    end

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
