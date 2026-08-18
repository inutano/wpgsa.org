# :)

# add current directory and lib directory to load path
$LOAD_PATH << __dir__
$LOAD_PATH << File.join(__dir__, "lib")

require 'sinatra'
require 'haml'
require 'yaml'
require 'json'

require 'lib/wpgsa'

class WpgsaApp < Sinatra::Base
  helpers do
    def app_root
      scheme = env["HTTP_X_FORWARDED_PROTO"] || env["rack.url_scheme"]
      "#{scheme}://#{env["HTTP_HOST"]}#{env["SCRIPT_NAME"]}"
    end
  end

  configure do
    set :config, YAML.load_file("./config.yaml")
  end

  get "/" do
    haml :index
  end

  get "/download" do
    haml :download
  end

  get "/result" do
    @uuid = params[:uuid] if params[:uuid]
    haml :result
  end

  get "/result/heatmap" do
    @uuid = params[:uuid] if params[:uuid]
    haml :heatmap
  end

  post "/wpgsa/result" do
    if params[:file]
      workdir = settings.config["workdir"]
      network_file_path = settings.config["network_file_path"]
      job = WPGSA::Job.create(params[:file], workdir, network_file_path)
      job.spawn!
      content_type "application/json"
      status 202
      JSON.dump({
        "uuid" => job.uuid,
        "status" => "queued"
      })
    end
  end

  get "/wpgsa/job" do
    content_type "application/json"
    job = WPGSA::Job.load(params[:uuid])
    JSON.dump(job.metadata)
  rescue WPGSA::InvalidDataId, Errno::ENOENT, JSON::ParserError
    status 404
    JSON.dump({
      "uuid" => params[:uuid],
      "status" => "unknown",
      "error_message" => "Job not found"
    })
  end

  get "/wpgsa/result" do
    uuid = params[:uuid]
    type = params[:type]
    result = WPGSA::Result.new(uuid, type)
    case params[:format]
    when "tsv"
      result.read
    when "filepath"
      result.result_file_path.sub(/^.+public/,"")
    else
      content_type "application/json"
      result.to_json
    end
  rescue WPGSA::InvalidDataId
    status 404
    content_type "application/json"
    JSON.dump({ "error_message" => "Not found" })
  end

  not_found do
    haml :not_found
  end
end
