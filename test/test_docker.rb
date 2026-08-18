require_relative "test_helper"
require "lib/wpgsa"
require "tmpdir"
require "stringio"

class TestDockerCommand < Minitest::Test
  def build(input_data: "sample.txt", network_file: "net.network")
    WPGSA::Docker.from_job(
      "d5767493-4b86-4297-8b8f-d650f413d952",
      "/tmp/wpgsa/d5767493-4b86-4297-8b8f-d650f413d952",
      "/srv/public/data/d5767493-4b86-4297-8b8f-d650f413d952",
      input_data,
      network_file
    )
  end

  def test_wpgsa_command_is_an_argument_array
    cmd = build.wpgsa_command
    assert_kind_of Array, cmd
    assert_equal "docker", cmd.first
  end

  def test_wpgsa_command_passes_paths_as_separate_arguments
    cmd = build.wpgsa_command
    assert_includes cmd, "--logfc-file"
    assert_includes cmd, "/data/sample.txt"
    assert_includes cmd, "--network-file"
    assert_includes cmd, "/data/net.network"
  end

  def test_wpgsa_command_does_not_quote_arguments
    # 引数配列で渡すのでシェルの引用符は不要。残っていたら
    # 文字列連結に戻っている印なので落とす。
    cmd = build.wpgsa_command
    refute(cmd.any? { |a| a.include?('"') })
  end

  def test_shell_metacharacters_stay_inside_one_argument
    cmd = build(input_data: 'a"; rm -rf /; echo "b').wpgsa_command
    injected = cmd.find { |a| a.start_with?("/data/a") }
    assert_equal '/data/a"; rm -rf /; echo "b', injected
    refute_includes cmd, "rm"
  end

  def test_hclust_command_is_an_argument_array
    cmd = build.hclust_command("sample.t_score.txt")
    assert_equal "docker", cmd.first
    assert_includes cmd, "hclust"
    assert_includes cmd, "/data/sample.t_score.txt"
  end

  def test_hclust_command_has_no_shell_redirect
    cmd = build.hclust_command("sample.t_score.txt")
    refute_includes cmd, ">"
    refute(cmd.any? { |a| a.include?(">") })
  end

  def test_safe_input_filename_strips_directory_components
    assert_equal "input-data-evil.js", build.safe_input_filename("../../evil.js")
  end

  def test_safe_input_filename_sanitises_unsafe_characters
    name = build.safe_input_filename("evil.js?/data.hclust.js")
    refute_includes name, "/"
    refute_includes name, "?"
    assert_match(/\A[A-Za-z0-9._-]+\z/, name)
  end

  def test_safe_input_filename_strips_leading_dots
    name = build.safe_input_filename("....htaccess")
    refute name.start_with?(".")
  end

  def test_safe_input_filename_handles_a_blank_name
    name = build.safe_input_filename("")
    assert_match(/\A[A-Za-z0-9._-]+\z/, name)
  end
end

# Integration-level test for Docker.new / staging / publish_result. This
# exercises real filesystem side effects (Docker#init_datadir hardcodes
# public/data/<uuid>), so it cleans up the directories it creates.
class TestDockerStagingHostileFilename < Minitest::Test
  def uploaded_file(filename, body = "a\tb\tc\n")
    { filename: filename, tempfile: StringIO.new(body) }
  end

  def with_network_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, "merged_mouse_150904_trim.network")
      File.write(path, "network contents")
      yield path
    end
  end

  def cleanup(docker)
    FileUtils.rm_rf(docker.workdir)
    FileUtils.rm_rf(docker.datadir)
  end

  # Finding 3: a hostile upload filename (e.g. one that resolves to a
  # same-origin script path once copied into public/data/<uuid>/) must not
  # survive staging or publishing under its original name.
  def test_hostile_upload_filename_does_not_survive_into_the_published_path
    with_network_file do |network_file_path|
      Dir.mktmpdir do |workdir_root|
        docker = WPGSA::Docker.new(uploaded_file("../../evil.js?/data.hclust.js"), workdir_root, network_file_path)
        begin
          refute_equal "../../evil.js?/data.hclust.js", docker.input_data
          refute_includes docker.input_data, "/"
          refute_includes docker.input_data, "?"

          docker.publish_result

          published = Dir.children(docker.datadir)
          refute_includes published, "evil.js"
          assert_includes published, docker.input_data
        ensure
          cleanup(docker)
        end
      end
    end
  end
end
