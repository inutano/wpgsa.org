require_relative "test_helper"
require "rack/test"
require "app"
require "fileutils"
require "json"

class TestApp < Minitest::Test
  include Rack::Test::Methods

  def app
    WpgsaApp
  end

  def test_index_renders
    get "/"
    assert last_response.ok?
    assert_includes last_response.body, "wPGSA"
  end

  def test_index_uses_the_forwarded_scheme_for_assets
    get "/", {}, { "HTTP_X_FORWARDED_PROTO" => "https", "HTTP_HOST" => "wpgsa.org" }
    assert_includes last_response.body, "https://wpgsa.org/css/wpgsa.css"
    refute_includes last_response.body, "http://wpgsa.org/css/"
  end

  def test_index_uses_the_forwarded_scheme_for_the_favicon
    get "/", {}, { "HTTP_X_FORWARDED_PROTO" => "https", "HTTP_HOST" => "wpgsa.org" }
    assert_includes last_response.body, "https://wpgsa.org/favicon.svg"
    assert_includes last_response.body, "https://wpgsa.org/favicon.ico"
    refute_includes last_response.body, "http://wpgsa.org/favicon"
  end

  def test_index_ignores_a_malformed_forwarded_proto_header
    get "/", {}, { "HTTP_X_FORWARDED_PROTO" => "https, http", "HTTP_HOST" => "wpgsa.org" }
    refute_includes last_response.body, "https, http://"
    assert_includes last_response.body, "http://wpgsa.org/css/wpgsa.css"
  end

  def test_download_renders
    get "/download"
    assert last_response.ok?
  end

  def test_unknown_path_renders_the_404_page
    get "/no-such-page"
    assert_equal 404, last_response.status
  end

  def test_unknown_css_is_not_a_server_error
    get "/nosuchstylesheet.css"
    assert_equal 404, last_response.status
  end

  def test_job_status_rejects_a_traversal_id
    get "/wpgsa/job", { uuid: "../../etc" }
    assert_equal 404, last_response.status
  end

  def test_result_page_rejects_an_invalid_uuid
    get "/result", { uuid: "example/../../etc/passwd" }
    assert_equal 404, last_response.status
  end

  def test_heatmap_page_rejects_an_invalid_uuid
    get "/result/heatmap", { uuid: "example/evil.js?" }
    assert_equal 404, last_response.status
  end

  def test_heatmap_page_does_not_point_the_script_tag_at_an_arbitrary_path
    get "/result/heatmap", { uuid: "example/evil.js?" }
    refute_includes last_response.body, "evil.js"
  end

  def test_result_page_renders_for_a_valid_uuid
    get "/result", { uuid: "example" }
    assert last_response.ok?
  end

  def test_heatmap_page_renders_for_a_valid_uuid
    get "/result/heatmap", { uuid: "example" }
    assert last_response.ok?
  end

  def test_result_and_heatmap_pages_render_the_modal_close_glyph_correctly
    get "/result", { uuid: "example" }
    assert_includes last_response.body, "×"
    refute_includes last_response.body, "&amp;times;"

    get "/result/heatmap", { uuid: "example" }
    assert_includes last_response.body, "×"
    refute_includes last_response.body, "&amp;times;"
  end

  def test_result_rejects_a_traversal_id
    get "/wpgsa/result", { uuid: "../../etc", type: "p-value", format: "tsv" }
    assert_equal 404, last_response.status
  end

  def test_upload_without_a_file_does_not_return_an_empty_200
    post "/wpgsa/result"
    refute_equal 200, last_response.status
  end

  def test_result_for_a_missing_job_directory_is_a_404
    get "/wpgsa/result", { uuid: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", type: "p-value", format: "tsv" }
    assert_equal 404, last_response.status
  end

  # GET /wpgsa/job is what the browser polls while a job is in flight, so
  # it has to reflect orphan correction (WPGSA::Job#metadata), not just
  # the raw persisted status -- otherwise the browser would poll a
  # "running" job that already died until it hits its own 30-minute
  # timeout and shows a generic timeout instead of telling the user the
  # analysis actually failed.
  def test_job_status_reflects_an_orphaned_job_as_failed
    uuid = "bbbbbbbb-cccc-dddd-eeee-ffffffffffff"
    data_dir = File.expand_path("../public/data/#{uuid}", __dir__)
    FileUtils.mkdir_p(data_dir)

    dead_pid = Process.spawn("true", out: File::NULL, err: File::NULL)
    Process.wait(dead_pid)

    File.write(File.join(data_dir, "job.json"), JSON.generate(
                                                    "uuid" => uuid,
                                                    "status" => "running",
                                                    "pid" => dead_pid,
                                                    "data_dir" => data_dir,
                                                    "workdir" => "/tmp/wpgsa/#{uuid}",
                                                    "input_filename" => "sample.txt",
                                                    "network_file" => "net.network"
                                                  ))

    get "/wpgsa/job", { uuid: uuid }
    body = JSON.parse(last_response.body)

    assert last_response.ok?
    assert_equal "failed", body["status"]
    assert_match(/died before completing/i, body["error_message"])

    persisted = JSON.parse(File.read(File.join(data_dir, "job.json")))
    assert_equal "failed", persisted["status"]
  ensure
    FileUtils.rm_rf(data_dir)
  end
end
