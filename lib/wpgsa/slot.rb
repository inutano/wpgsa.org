require 'fileutils'

module WPGSA
  # 解析コンテナの同時実行数を、ファイルロックで上限まで絞る。
  # 上限に達しているあいだ acquire はブロックするので、
  # 呼び出し側のジョブは queued のまま待つ。
  class Slot
    DEFAULT_DIR = File.join(__dir__, "../../tmp/slots").freeze

    def self.acquire(limit, dir: DEFAULT_DIR, poll: 5)
      FileUtils.mkdir_p(dir)

      loop do
        limit.times do |i|
          file = File.open(File.join(dir, "slot#{i}.lock"), File::RDWR | File::CREAT, 0o644)
          if file.flock(File::LOCK_EX | File::LOCK_NB)
            begin
              return yield
            ensure
              file.flock(File::LOCK_UN)
              file.close
            end
          end
          file.close
        end

        sleep poll
      end
    end
  end
end
