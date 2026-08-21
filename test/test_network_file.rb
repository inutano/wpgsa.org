require_relative "test_helper"
require "app"

# The reference network is an input to a container the site does not
# build: inutano/wpgsa:0.5.2 runs wPGSA.py 1.1.0, whose read_network
# takes column 2 as the target gene, column 3 as `positive No.` and
# column 4 as `experiment No.` (0-indexed), i.e. a five-column file.
#
# Nothing in the Ruby app looks inside the network file, so shipping one
# in a layout the container does not parse fails silently: the analysis
# still exits zero and still produces a full result table, only with the
# weights computed from the wrong columns. That is exactly what happened
# between 2026-08-18 and this fix, when config.yaml was pointed at the
# six-column merged_mouse_150904_trim.network, whose extra Target_geneID
# column shifts every index by one and turns the per-gene weight into
# `Entrez gene ID / positive No.`.
class TestNetworkFile < Minitest::Test
  # Column names as of the five-column format the container parses.
  EXPECTED_HEADER = %w[TF_Uniprot TF_egSym TargetSym].freeze
  POSITIVE_COLUMN = 3
  EXPERIMENT_COLUMN = 4
  EXPECTED_COLUMN_COUNT = 5

  def network_file_path
    WpgsaApp.settings.config["network_file_path"]
  end

  def test_configured_network_file_exists
    assert File.exist?(network_file_path),
           "network_file_path does not exist: #{network_file_path}"
  end

  def test_header_names_the_five_columns_the_container_parses
    header = File.open(network_file_path, &:readline).chomp.split("\t")

    assert_equal EXPECTED_COLUMN_COUNT, header.size,
                 "expected a five-column network, got #{header.size}: #{header.inspect}"
    assert_equal EXPECTED_HEADER, header.first(3)
    assert_match(/positive/i, header[POSITIVE_COLUMN])
    assert_match(/experiment/i, header[EXPERIMENT_COLUMN])
  end

  # The property that actually distinguishes a correctly-parsed file from
  # a shifted one. The container's weight is
  # `positive No. / experiment No.`, the fraction of a transcription
  # factor's ChIP experiments in which the target gene was bound, so it
  # can never exceed 1. Under the six-column file the same two indices
  # hold Target_geneID and positive No., and the "fraction" comes out in
  # the tens of thousands.
  def test_every_row_weights_a_binding_frequency_of_at_most_one
    offenders = []
    row_count = 0

    File.foreach(network_file_path).with_index do |line, index|
      next if index.zero? # header
      break if offenders.size >= 3

      fields = line.chomp.split("\t")
      row_count += 1

      if fields.size != EXPECTED_COLUMN_COUNT
        offenders << "line #{index + 1}: #{fields.size} columns, not #{EXPECTED_COLUMN_COUNT}"
        next
      end

      positive = Integer(fields[POSITIVE_COLUMN], exception: false)
      experiment = Integer(fields[EXPERIMENT_COLUMN], exception: false)

      if positive.nil? || experiment.nil?
        offenders << "line #{index + 1}: non-integer counts #{fields.last(2).inspect}"
      elsif experiment < 1 || positive > experiment
        offenders << "line #{index + 1}: positive=#{positive} experiment=#{experiment}"
      end
    end

    assert_operator row_count, :>, 0, "network file has no data rows"
    assert_empty offenders,
                 "network file is not in the layout wPGSA.py parses; first offenders: #{offenders.inspect}"
  end

  # The bootstrap refuses to provision a host whose checkout is missing
  # the reference network, which means it names the file a second time --
  # and a second name is a second thing to forget. When the two drift, the
  # provisioning check passes against a file the app no longer uses, or
  # fails against one that is present under a different name.
  def test_bootstrap_checks_for_the_network_file_config_yaml_names
    script = File.read(File.join(WPGSA::APP_ROOT, "script/bootstrap-wpgsa-instance.sh"))
    configured = File.basename(WpgsaApp.settings.config["network_file_path"])

    stale = script.scan(/[\w.-]+\.network/).uniq.reject { |name| name == configured }

    assert_empty stale,
                 "script/bootstrap-wpgsa-instance.sh names a network file config.yaml does not: #{stale.inspect}"
  end
end
