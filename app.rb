# :)

# add current directory and lib directory to load path
$LOAD_PATH << __dir__
$LOAD_PATH << File.join(__dir__, "lib")

require 'sinatra'
require 'haml'
require 'sass'
require 'yaml'
require 'json'

require 'lib/wpgsa'

class WpgsaApp < Sinatra::Base
  helpers do
    def app_root
      "#{env["rack.url_scheme"]}://#{env["HTTP_HOST"]}#{env["SCRIPT_NAME"]}"
    end
  end

  configure do
    set :config, YAML.load_file("./config.yaml")
  end

  get "/:source.css" do
    sass params[:source].intern
  end

  get "/" do
    haml :index
  end

  get "/result" do
    haml :result
  end

  post "/wpgsa/result" do
    if params[:file]
      workdir = settings.config["workdir"]
      network_file_path = settings.config["network_file_path"]
      d = WPGSA::Docker.new(params[:file], workdir, network_file_path)
      content_type "application/json"
      JSON.dump(d.wpgsa_results)
    end
  end

  get "/wpgsa/result" do
    uuid = params[:uuid]
    type = params[:type]
    result = WPGSA::Result.new(uuid, type)
    case params[:format]
    when "tsv"
      result.read
    else
      content_type "application/json"
      result.to_json
    end
  end

  not_found do
    haml :not_found
  end
end
