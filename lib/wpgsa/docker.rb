require 'securerandom'
require 'fileutils'

module WPGSA
  class Docker
    def initialize(input_file, workdir, network_file_path) # file object from params[:file]
      @uuid = SecureRandom.uuid

      @workdir = init_workdir(workdir)
      @datadir = init_datadir

      @input_data = staging_input_data(input_file)
      @network_file = staging_network_file(network_file_path)
    end

    def wpgsa_container_id
      "inutano/wpgsa:0.5.0"
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

    def staging_input_data(input_file) # return input file name
      fname = input_file[:filename].encode('utf-8', :invalid => :replace, :undef => :replace ).gsub(/\s/,"_")
      input_data = input_file[:tempfile].read.encode('utf-8')
      open(File.join(@workdir, fname), "w"){|f| f.puts(input_data) }
      fname
    rescue
      warn "Failed to stage input data: #{Time.now}"
      warn "  Filename: #{fname}"
      warn "  File: #{input_file[:tempfile].read}"
      exit 1
    end

    def staging_network_file(network_file_path) # return network file name
      raise Errno::ENOENT if !File.exist?(network_file_path)
      FileUtils.cp(network_file_path, @workdir)
      network_file_path.split("/").last
    end

    def run_wpgsa
      docker_cmd       = "docker run --rm -i -v #{@workdir}:/data #{wpgsa_container_id} wpgsa"
      input_argument   = "--logfc-file /data/#{@input_data}"
      network_argument = "--network-file /data/#{@network_file}"
      cmd = [docker_cmd, input_argument, network_argument].join("\s")
      `#{cmd}`
      raise NameError if $? != 0
    end

    def run_hclust
      t_score = Dir.glob(@workdir+"/*t_score*").first.split("/").last
      docker_cmd = "docker run --rm -i -v #{@workdir}:/data #{wpgsa_container_id} hclust"
      arguments  = "/data/#{t_score} > #{@workdir}/data.hclust.js"
      `#{docker_cmd} #{arguments}`
      raise NameError if $? != 0
    end

    def publish_result
      FileUtils.cp_r(Dir.glob("#{@workdir}/*"), @datadir)
    end

    def wpgsa_results
      run_wpgsa
      run_hclust
      publish_result
      Dir.glob("#{@datadir}/*").map{|path| path.sub(/^.+\/public\//,"") }
    rescue NameError
      nil
    end

    def dry_run
      Dir.glob("#{File.join(__dir__, "../../public/data", "d5767493-4b86-4297-8b8f-d650f413d952")}/*").map{|path| path.sub(/^.+\/public\//,"") }
    end
  end
end
