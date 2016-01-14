require 'securerandom'
require 'fileutils'

module WPGSA
  class Docker
    def initialize(input_file, network_file_path) # file object from params[:file]
      @fname   = input_file[:filename]
      @input   = input_file[:tempfile].read
      @datadir = init_datadir
      @network_file = network_file_path
      raise Errno::ENOENT if !File.exist?(@network_file)
      staging
    end

    def init_datadir
      datadir = File.join(__dir__, "../../public/data", SecureRandom.uuid)
      FileUtils.mkdir_p(datadir)
      datadir
    end

    def staging
      FileUtils.cp(@network_file, @datadir)
      open(File.join(@datadir, @fname), "w"){|f| f.puts(@input) }
    end

    def run
      docker_cmd       = "docker run -it -v #{@datadir}:/data inutano/wpgsa wpgsa"
      input_argument   = "--logfc-file /data/#{@fname}"
      network_argument = "--network-file /data/#{@network_file.split("/").last}"
      cmd = [docker_cmd, input_argument, network_argument].join("\s")
      puts cmd
      `#{cmd}`
    end

    def wpgsa_results
      run
      Dir.glob("#{@datadir}/*").map{|path| path.sub(/^.+\/public\//,"") }
    end
  end
end
