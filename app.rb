# :)

# add current directory and lib directory to load path
$LOAD_PATH << __dir__
$LOAD_PATH << File.join(__dir__, "lib")

require 'sinatra'
require 'sinatra/activerecord'
require 'haml'
require 'sass'
require 'open-uri'
require 'net/http'
require 'json'
require 'fileutils'

ENV["DATABASE_URL"] ||= "sqlite3:database.sqlite"

class WPGSA < Sinatra::Base
  register Sinatra::ActiveRecordExtension
  set :database, ENV["DATABASE_URL"]

  helpers do
    def app_root
      "#{env["rack.url_scheme"]}://#{env["HTTP_HOST"]}#{env["SCRIPT_NAME"]}"
    end
  end

  configure do
  end

  get "/:source.css" do
    sass params[:source].intern
  end

  get "/" do
    haml :index
  end

  post "/wpgsa/result" do
  end

  not_found do
    haml :not_found
  end
end
