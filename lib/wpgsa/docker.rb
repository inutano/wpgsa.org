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

    def init_workdir(workdir)
      workdir = File.join(workdir, @uuid)
      FileUtils.mkdir_p(workdir)
      workdir
    end

    def init_datadir
      datadir = File.join(__dir__, "../../public/data", @uuid)
      FileUtils.mkdir_p(datadir)
      datadir
    end

    def staging_input_data(input_file) # return input file name
      input_data = File.join(@workdir, input_file[:filename])
      open(input_data, "w"){|f| f.puts(input_file[:tempfile].read) }
      input_data
    end

    def staging_network_file(network_file_path) # return network file name
      raise Errno::ENOENT if !File.exist?(network_file_path)
      FileUtils.cp(network_file_path, @workdir)
      network_file_path.split("/").last
    end

    def run
      docker_cmd       = "docker run -i -v #{@workdir}:/data inutano/wpgsa wpgsa"
      input_argument   = "--logfc-file /data/#{@input_data}"
      network_argument = "--network-file /data/#{@network_file}"
      cmd = [docker_cmd, input_argument, network_argument].join("\s")
      `#{cmd}`
    end

    def publish_result
      FileUtils.cp_r(Dir.glob("#{@workdir}/*"), @datadir)
    end

    def wpgsa_results
      run
      publish_result
      Dir.glob("#{@datadir}/*").map{|path| path.sub(/^.+\/public\//,"") }
    end
  end
end
