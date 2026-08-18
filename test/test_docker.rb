require_relative "test_helper"
require "lib/wpgsa"

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
end
