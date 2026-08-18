require_relative "test_helper"
require "lib/wpgsa/log_filter"
require "tmpdir"

class TestLogFilter < Minitest::Test
  def filtered(*chunks)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "job.log")
      File.open(path, "wb") do |out|
        filter = WPGSA::LogFilter.new(out)
        chunks.each { |chunk| filter << chunk }
        filter.finish
      end
      File.read(path)
    end
  end

  # The real-world case this exists to fix: a progress bar that only
  # ever uses \r, never \n, must not survive into the log at all.
  def test_drops_a_carriage_return_only_progress_bar_entirely
    progress = (1..100).map { |pct| "progress: #{pct}%\r" }.join
    assert_equal "", filtered(progress)
  end

  def test_keeps_an_ordinary_newline_terminated_line
    assert_equal "starting analysis\n", filtered("starting analysis\n")
  end

  def test_a_progress_bar_that_ends_with_a_real_newline_keeps_only_the_final_state
    output = "0%\r50%\r100%\ndone\n"
    assert_equal "100%\ndone\n", filtered(output)
  end

  def test_strips_ansi_escape_sequences_from_kept_lines
    output = "\e[32mOK\e[0m: step complete\n"
    assert_equal "OK: step complete\n", filtered(output)
  end

  def test_handles_windows_style_crlf_line_endings_as_ordinary_lines
    assert_equal "line one\nline two\n", filtered("line one\r\nline two\r\n")
  end

  # On a failing job the container's traceback is the only diagnostic
  # information available; the filter must not eat it.
  def test_keeps_a_traceback_shaped_multi_line_block
    traceback = <<~TRACE
      Traceback (most recent call last):
        File "wpgsa.py", line 42, in run
          raise ValueError("bad network file")
      ValueError: bad network file
    TRACE
    assert_equal traceback, filtered(traceback)
  end

  def test_mixes_progress_churn_and_real_output_correctly
    output = +""
    output << "loading network...\n"
    output << (1..50).map { |pct| "\r#{pct}%" }.join
    output << "\rdone\n"
    output << "Traceback (most recent call last):\n"
    output << "RuntimeError: analysis failed\n"

    expected = "loading network...\ndone\nTraceback (most recent call last):\nRuntimeError: analysis failed\n"
    assert_equal expected, filtered(output)
  end

  def test_a_chunk_boundary_falling_between_cr_and_lf_is_still_treated_as_one_newline
    assert_equal "line\n", filtered("line\r", "\n")
  end
end
