namespace :wpgsa do
  desc "initialize repository"
  task :init => [:rewrite_config]

  task :rewrite_config do
    config_file = File.join(PROJ_ROOT, "config.yaml")
    content = open(config_file).read
    updated = content.sub(/^network_file.+$/, "network_file: #{File.join(PROJ_ROOT, "data/merged_mouse_150904_trim.network")}")
  end
end
