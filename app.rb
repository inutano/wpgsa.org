# :)

# add current directory and lib directory to load path
$LOAD_PATH << __dir__
$LOAD_PATH << File.join(__dir__, "lib")

require 'sinatra'
require 'haml'
require 'sass'
require 'yaml'

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

  post "/wpgsa/result" do
    if params[:file]
      d = WPGSA::Docker.new(params[:file], settings.config["network_file_path"])
      content_type "application/json"
      JSON.dump(d.wpgsa_results)
    end
  end

  not_found do
    haml :not_found
  end
end
