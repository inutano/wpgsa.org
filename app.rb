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
    ALLOWED_FORWARDED_SCHEMES = %w[http https].freeze

    def app_root
      forwarded = env["HTTP_X_FORWARDED_PROTO"]
      scheme = ALLOWED_FORWARDED_SCHEMES.include?(forwarded) ? forwarded : env["rack.url_scheme"]
      "#{scheme}://#{env["HTTP_HOST"]}#{env["SCRIPT_NAME"]}"
    end
  end

  configure do
    config = YAML.load_file(File.expand_path("config.yaml", __dir__))
    # network_file_path in config.yaml is a relative path so the tracked
    # file is identical on every host. Resolve it against the app root
    # here rather than rewriting the file at provision time -- see
    # WPGSA.resolve_app_path.
    config["network_file_path"] = WPGSA.resolve_app_path(config["network_file_path"])
    set :config, config
  end

  get "/" do
    haml :index
  end

  get "/download" do
    haml :download
  end

  get "/result" do
    if params[:uuid]
      WPGSA.validate_data_id!(params[:uuid])
      @uuid = params[:uuid]
    end
    haml :result
  rescue WPGSA::InvalidDataId
    status 404
    haml :not_found
  end

  get "/result/heatmap" do
    if params[:uuid]
      WPGSA.validate_data_id!(params[:uuid])
      @uuid = params[:uuid]
    end
    haml :heatmap
  rescue WPGSA::InvalidDataId
    status 404
    haml :not_found
  end

  post "/wpgsa/result" do
    content_type "application/json"

    if !params[:file]
      status 400
      return JSON.dump({ "error_message" => "No file was uploaded" })
    end

    workdir = settings.config["workdir"]
    network_file_path = settings.config["network_file_path"]
    job = WPGSA::Job.create(params[:file], workdir, network_file_path)
    job.spawn!

    status 202
    JSON.dump({
      "uuid" => job.uuid,
      "status" => "queued"
    })
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
  rescue WPGSA::InvalidDataId, Errno::ENOENT
    status 404
    content_type "application/json"
    JSON.dump({ "error_message" => "Not found" })
  end

  not_found do
    haml :not_found
  end
end
