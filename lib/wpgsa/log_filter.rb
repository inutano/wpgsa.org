module WPGSA
  # The wpgsa container's stdout is a carriage-return progress bar: many
  # updates to the same terminal line, almost all of which are
  # overwritten before the process exits and mean nothing once it does.
  # Piped straight into job.log this is enormous and useless -- a real
  # successful job wrote 276,883 bytes across 6,454 updates and not one
  # line of any other content, on a 30 GiB volume that pays for every one
  # of those bytes per job.
  #
  # LogFilter reconstructs "real" lines from a raw byte stream the way a
  # terminal would: a lone \r returns to the start of the current line,
  # discarding whatever had been buffered for it (that text is about to
  # be overwritten), while \n -- bare, or as the second half of \r\n --
  # commits the line. ANSI escape sequences are stripped from committed
  # lines. Anything still buffered when the stream ends without a
  # terminating \n is dropped rather than guessed at: that is exactly
  # what a progress bar's last update looks like (no trailing newline,
  # because the process just exits), whereas real diagnostic output --
  # including a container's traceback on a failing job, which is the
  # entire reason this log exists -- is expected to end its lines with
  # \n.
  class LogFilter
    # A reasonably standard "strip ANSI" pattern: CSI sequences (colors,
    # cursor moves, clear-line -- the ones progress bars actually use),
    # OSC sequences terminated by BEL, and the short two-byte Fe escapes.
    ANSI_ESCAPE = /\x1B\[[0-?]*[ -\/]*[@-~]|\x1B\][^\x07]*\x07|\x1B[@-_]/.freeze

    CR = 13
    LF = 10

    def initialize(output)
      @output = output
      @pending = +"".b
      @saw_cr = false
    end

    # Feed a chunk of raw bytes from the runner's stdout/stderr. Chunk
    # boundaries do not need to line up with \r/\n boundaries.
    def <<(chunk)
      chunk.b.each_byte { |byte| process_byte(byte) }
      self
    end

    # Called once, at end-of-stream. Deliberately does not flush
    # whatever is left in @pending -- see the class comment.
    def finish
      @pending = +"".b
      @saw_cr = false
      nil
    end

    private

    def process_byte(byte)
      if @saw_cr
        @saw_cr = false
        if byte == LF
          # \r\n: an ordinary line ending, not a cursor return. Keep
          # whatever was buffered.
          flush_pending
          return
        else
          # A lone \r: the terminal's cursor went back to the start of
          # the line, so whatever was buffered is about to be
          # overwritten and never meant anything on its own.
          @pending = +"".b
        end
      end

      case byte
      when CR
        @saw_cr = true
      when LF
        flush_pending
      else
        @pending << byte
      end
    end

    def flush_pending
      @output.write(@pending.gsub(ANSI_ESCAPE, ""))
      @output.write("\n")
      @pending = +"".b
    end
  end
end
