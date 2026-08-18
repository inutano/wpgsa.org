require 'securerandom'
require 'fileutils'

module WPGSA
  class Docker
    attr_reader :uuid, :workdir, :datadir, :input_data, :network_file

    def initialize(input_file, workdir, network_file_path) # file object from params[:file]
      @uuid = SecureRandom.uuid

      @workdir = init_workdir(workdir)
      @datadir = init_datadir

      @input_data = staging_input_data(input_file)
      @network_file = staging_network_file(network_file_path)
    end

    def self.from_job(uuid, workdir, datadir, input_data, network_file)
      job = allocate
      job.instance_variable_set(:@uuid, uuid)
      job.instance_variable_set(:@workdir, workdir)
      job.instance_variable_set(:@datadir, datadir)
      job.instance_variable_set(:@input_data, input_data)
      job.instance_variable_set(:@network_file, network_file)
      job
    end

    def wpgsa_container_id
      "inutano/wpgsa:0.5.2"
    end

    def init_workdir(workdir)
      workdir = File.join(workdir, @uuid)
      FileUtils.mkdir_p(workdir)
      FileUtils.chmod(0777, workdir)
      workdir
    end

    def init_datadir
      datadir = File.join(__dir__, "../../public/data", @uuid)
      FileUtils.mkdir_p(datadir)
      datadir
    end

    # A fixed prefix plus a sanitised basename of the client-supplied
    # filename. The container is invoked with an argv array (see
    # wpgsa_command below), so this only needs to be filesystem- and
    # web-safe, not shell-safe -- but the staged file is also copied
    # verbatim into the web-served public/data/<uuid>/ directory by
    # publish_result, so an unsanitised name (e.g. "evil.js") would be
    # served from the site's own origin as JavaScript. Restrict it to a
    # safe character set and strip any leading dots so it can't resolve to
    # a dotfile or, in combination with a traversal-ish uuid, escape the
    # job directory.
    SAFE_INPUT_BASENAME_PATTERN = /[^A-Za-z0-9._-]/

    def staging_input_data(input_file) # return input file name
      fname = safe_input_filename(input_file[:filename])
      input_data = input_file[:tempfile].read.encode('utf-8')
      open(File.join(@workdir, fname), "w"){|f| f.puts(input_data) }
      fname
    rescue
      warn "Failed to stage input data: #{Time.now}"
      warn "  Filename: #{fname}"
      warn "  File: #{input_file[:tempfile].read}"
    end

    def safe_input_filename(raw_filename)
      basename = raw_filename.to_s
        .encode('utf-8', :invalid => :replace, :undef => :replace)
        .gsub(/\s/, "_")
      basename = File.basename(basename)
      basename = basename.gsub(SAFE_INPUT_BASENAME_PATTERN, "_")
      basename = basename.sub(/\A\.+/, "")
      basename = "input" if basename.empty?
      "input-data-#{basename}"
    end

    def staging_network_file(network_file_path) # return network file name
      raise Errno::ENOENT if !File.exist?(network_file_path)
      FileUtils.cp(network_file_path, @workdir)
      network_file_path.split("/").last
    end

    def wpgsa_command
      [
        "docker", "run", "--rm", "-i",
        "-v", "#{@workdir}:/data",
        wpgsa_container_id, "wpgsa",
        "--logfc-file", "/data/#{@input_data}",
        "--network-file", "/data/#{@network_file}"
      ]
    end

    def hclust_command(t_score)
      [
        "docker", "run", "--rm", "-i",
        "-v", "#{@workdir}:/data",
        wpgsa_container_id, "hclust",
        "/data/#{t_score}"
      ]
    end

    def run_wpgsa
      raise AnalysisFailed, "wpgsa container exited non-zero" unless system(*wpgsa_command)
    end

    def run_hclust
      t_score_path = Dir.glob(File.join(@workdir, "*t_score*")).first
      return if !t_score_path

      # 1 サンプルのみの入力ではクラスタリング結果が出ないため、
      # 失敗しても解析全体は成功として扱う
      File.open(File.join(@workdir, "data.hclust.js"), "w") do |out|
        system(*hclust_command(File.basename(t_score_path)), out: out)
      end
    end

    def publish_result
      FileUtils.cp_r(Dir.glob("#{@workdir}/*"), @datadir)
    end

    def run_analysis
      run_wpgsa
      run_hclust
      publish_result
      result_paths
    end

    def result_paths
      Dir.glob("#{@datadir}/*").map{|path| path.sub(/^.+\/public\//,"") }
    end
  end
end
