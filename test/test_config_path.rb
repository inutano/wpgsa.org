require_relative "test_helper"
require "app"
require "yaml"

# Covers the fix for the config-rewrite bug: config.yaml's
# network_file_path is a relative path so the tracked file is identical
# on every host, and WPGSA.resolve_app_path -- not a provision-time
# rewrite of config.yaml -- is what turns it into a usable absolute
# path. See script/bootstrap-wpgsa-instance.sh#configure_app.
class TestConfigPath < Minitest::Test
  def test_resolve_app_path_expands_a_relative_path_against_the_root
    root = "/opt/wpgsa.org"
    resolved = WPGSA.resolve_app_path("./data/example.network", root: root)
    assert_equal File.join(root, "data/example.network"), resolved
  end

  def test_resolve_app_path_leaves_an_absolute_path_untouched
    absolute = "/custom/network/path.network"
    resolved = WPGSA.resolve_app_path(absolute, root: "/opt/wpgsa.org")
    assert_equal absolute, resolved
  end

  def test_resolve_app_path_defaults_to_the_application_root
    resolved = WPGSA.resolve_app_path("./data/example.network")
    assert_equal File.join(WPGSA::APP_ROOT, "data/example.network"), resolved
  end

  # This is the property that actually broke: the checked-in config.yaml
  # carries a relative network_file_path, and loading the app must yield
  # a usable absolute path to the real reference network file without
  # ever writing to config.yaml -- no host-specific rewrite required.
  # Asserted against whatever config.yaml names rather than against a
  # hard-coded filename: the property under test is that the tracked value
  # stays relative and still resolves to a real file, and pinning the name
  # here only means this test has to be edited whenever the reference
  # network is replaced -- which is precisely when it should be checking,
  # not being rewritten. TestNetworkFile covers the file's contents.
  def test_app_config_resolves_the_checked_in_relative_path_to_an_absolute_file
    on_disk = YAML.load_file(File.join(WPGSA::APP_ROOT, "config.yaml"))
    configured = on_disk["network_file_path"]

    refute File.absolute_path?(configured),
           "config.yaml should hold a relative, host-independent path, got #{configured.inspect}"

    resolved = WpgsaApp.settings.config["network_file_path"]

    assert File.absolute_path?(resolved), "expected an absolute path, got #{resolved.inspect}"
    assert_equal File.expand_path(configured, WPGSA::APP_ROOT), resolved
    assert File.exist?(resolved), "resolved network_file_path does not exist: #{resolved}"
  end
end
