require_relative "test_helper"
require "rack/test"
require "app"

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
end
