namespace :wpgsa do
  desc "initialize repository"
  task :init => [:start, :fix_path_to_network_file, :finish]

  task :start do
    puts "=> Start configulation..."
  end

  task :fix_path_to_network_file do
    config_file = File.join(PROJ_ROOT, "config.yaml")
    content = open(config_file).read
    updated = content.sub(/^network_file.+$/, "network_file: #{File.join(PROJ_ROOT, "data/merged_mouse_150904_trim.network")}")
    open(config_file,"w"){|f| f.puts(updated) }
    puts "=> rewriting path to network file"
  end

  task :finish do
    puts "=> finished configulation."
  end
end
