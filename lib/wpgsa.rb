require 'wpgsa/docker'
require 'wpgsa/job'
require 'wpgsa/log_filter'
require 'wpgsa/result'
require 'wpgsa/slot'

module WPGSA
  class InvalidDataId < StandardError; end
  class AnalysisFailed < StandardError; end

  UUID_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  EXAMPLE_ID = "example".freeze
  DATA_ROOT = File.expand_path(File.join(__dir__, "../public/data")).freeze

  def self.valid_data_id?(id)
    return false unless id.is_a?(String)
    return true if id == EXAMPLE_ID

    UUID_PATTERN.match?(id)
  end

  def self.validate_data_id!(id)
    raise InvalidDataId, "invalid data id" unless valid_data_id?(id)

    id
  end

  # True iff `path`, once expanded, genuinely sits inside `root` (also
  # expanded) -- not merely a string that happens to start with `root`.
  # Comparing against `root + File::SEPARATOR`, rather than bare `root`,
  # is what keeps a sibling directory whose name merely starts with the
  # root's name (root "data" vs sibling "data-evil") from passing.
  def self.path_within_root?(path, root)
    root = File.expand_path(root)
    path = File.expand_path(path)
    path == root || path.start_with?(root + File::SEPARATOR)
  end

  # Resolves a job/result id to its data directory under DATA_ROOT, and
  # proves -- not just assumes -- that the resolved path is actually
  # contained within that root.
  #
  # validate_data_id! alone already makes this safe in practice: its
  # regex admits no path separators or dot segments, so File.join(
  # DATA_ROOT, id) can never walk outside DATA_ROOT. But that guarantee
  # lives one method away from the File.join call it protects, which is
  # exactly what a static taint tracker -- CodeQL's rb/path-injection
  # query included -- cannot see across a call boundary. Routing every
  # data-directory construction through this method gives the analysis a
  # containment check it *can* verify, and it is genuine defence in
  # depth besides: if the id pattern is ever loosened by a future
  # change, this check still holds even after the regex alone would not.
  def self.data_dir(id)
    validate_data_id!(id)

    candidate = File.expand_path(File.join(DATA_ROOT, id))
    unless path_within_root?(candidate, DATA_ROOT)
      raise InvalidDataId, "resolved data path escapes the data root"
    end

    candidate
  end
end
