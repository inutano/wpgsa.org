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
      "inutano/wpgsa:0.4.0"
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
      fname = input_file[:filename]
      open(File.join(@workdir, fname), "w"){|f| f.puts(input_file[:tempfile].read) }
      fname
    end

    def staging_network_file(network_file_path) # return network file name
      raise Errno::ENOENT if !File.exist?(network_file_path)
      FileUtils.cp(network_file_path, @workdir)
      network_file_path.split("/").last
    end

    def run_wpgsa
      docker_cmd       = "docker run -i -v #{@workdir}:/data #{wpgsa_container_id} wpgsa"
      input_argument   = "--logfc-file /data/#{@input_data}"
      network_argument = "--network-file /data/#{@network_file}"
      cmd = [docker_cmd, input_argument, network_argument].join("\s")
      `#{cmd}`
    end

    def run_hclust
      z_score = Dir.glob(@workdir+"/*z_score*").first.split("/").last
      docker_cmd = "docker run -i -v #{@workdir}:/data #{wpgsa_container_id} hclust"
      arguments  = "/data/#{z_score} > #{@workdir}/data.hclust.js"
      `#{docker_cmd} #{arguments}`
    end

    def publish_result
      FileUtils.cp_r(Dir.glob("#{@workdir}/*"), @datadir)
    end

    def wpgsa_results
      run_wpgsa
      run_hclust
      publish_result
      Dir.glob("#{@datadir}/*").map{|path| path.sub(/^.+\/public\//,"") }
    end

    def dry_run
      Dir.glob("#{File.join(__dir__, "../../public/data", "d5767493-4b86-4297-8b8f-d650f413d952")}/*").map{|path| path.sub(/^.+\/public\//,"") }
    end
  end
end
