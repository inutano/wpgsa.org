require 'securerandom'
require 'fileutils'
require 'rake'

module WPGSA
  class Docker
    def initialize(input_file, workdir, network_file) # file object from params[:file]
      @fname   = input_file[:filename]
      @input   = input_file[:tempfile].read
      @workdir = init_workdir(workdir)
      @network_file = network_file
      staging
    end

    def init_workdir
      workdir = File.join(__dir__, "../../tmp", SecureRandom.uuid)
      FileUtils.mkdir_p(workdir) if !File.exist?(workdir)
      workdir
    end

    def staging
      FileUtils.cp(@network_file, @workdir)
      open(File.join(@workdir, @fname), "w"){|f| f.puts(@input) }
    end

    def network_filename
      @network_file.split("/").last
    end

    def run
      sh "docker run -it -v #{workdir}:/data inutano/wpgsa wpgsa --logfc-file /data/#{@fname} --network-file /data/#{network_filename}"
    end
  end
end
