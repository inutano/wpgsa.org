require 'json'

module WPGSA
  class Result
    def initialize(uuid, type)
      @uuid = uuid
      @type = type
      @data_dir = File.join(__dir__, "../../public/data", @uuid)
    end

    def read
      open(result_file_path).read
    end

    def to_json
      data = parse_tsv(result_file_path)
      JSON.dump(data)
    end

    def result_file_path
      case @type
      when "p-value"
        p_value
      when "q-value"
        q_value
      when "z-score"
        z_score
      when "input"
        input_data
      when "network"
        network_data
      end
    end

    def p_value
      glob("p_value.txt")
    end

    def q_value
      glob("q_value.txt")
    end

    def z_score
      glob("z_score.txt")
    end

    def network_data
      glob(".network")
    end

    def hclust
      glob("hclust.js")
    end

    def input_data
      fpath = Dir.glob(@data_dir+"/*").select do |f|
        f != p_value && f != q_value && f != z_score && f != network_data && f != hclust
      end
      fpath[0]
    end

    def glob(type)
      fpath = Dir.glob(@data_dir+"/*#{type}").first
    end

    def parse_tsv(file_path)
      open(file_path).readlines.map do |ln|
        ln.chomp.split("\t")
      end
    end
  end
end
