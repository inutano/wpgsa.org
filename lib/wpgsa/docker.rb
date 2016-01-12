require 'securerandom'
require 'fileutils'

module WPGSA
  class Docker
    def initialize(input_file, workdir, network_file) # file object from params[:file]
      @fname   = input_file[:filename]
      @input   = input_file[:tempfile].read
      @datadir = init_datadir(workdir)
      @network_file = network_file
      @network_fname = @network_file.split("/").last
      staging
    end

    def init_datadir(workdir)
      datadir = File.join(workdir, SecureRandom.uuid)
      FileUtils.mkdir_p(datadir)
      datadir
    end

    def staging
      FileUtils.cp(@network_file, @datadir)
      open(File.join(@datadir, @fname), "w"){|f| f.puts(@input) }
    end

    def run
      `docker run -it -v #{@datadir}:/data inutano/wpgsa wpgsa --logfc-file /data/#{@fname} --network-file /data/#{@network_fname}`
    end

    def clean
      FileUtils.rm(File.join(@datadir, @network_fname))
    end
  end
end
