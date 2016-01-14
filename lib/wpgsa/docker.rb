require 'securerandom'
require 'fileutils'

module WPGSA
  class Docker
    def initialize(input_file, network_file_path) # file object from params[:file]
      @fname   = input_file[:filename]
      @input   = input_file[:tempfile].read
      @datadir = init_datadir
      @network_file = network_file_path
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
      `docker run -it -v #{@datadir}:/data inutano/wpgsa wpgsa --logfc-file /data/#{@fname} --network-file /data/#{@network_file.split("/").last}`
    end

    def wpgsa_results
      run
      Dir.glob("#{@datadir}/*")
    end
  end
end
