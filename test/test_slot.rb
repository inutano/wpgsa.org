require_relative "test_helper"
require "lib/wpgsa"
require "tmpdir"
require "timeout"

class TestSlot < Minitest::Test
  def test_runs_the_block_and_returns_its_value
    Dir.mktmpdir do |dir|
      result = WPGSA::Slot.acquire(2, dir: dir) { :done }
      assert_equal :done, result
    end
  end

  def test_releases_the_slot_after_the_block
    Dir.mktmpdir do |dir|
      WPGSA::Slot.acquire(1, dir: dir) { :first }
      # 直前の呼び出しが解放していなければ、ここでブロックして
      # タイムアウトする
      result = WPGSA::Slot.acquire(1, dir: dir) { :second }
      assert_equal :second, result
    end
  end

  def test_releases_the_slot_when_the_block_raises
    Dir.mktmpdir do |dir|
      assert_raises(RuntimeError) do
        WPGSA::Slot.acquire(1, dir: dir) { raise "boom" }
      end
      result = WPGSA::Slot.acquire(1, dir: dir) { :after }
      assert_equal :after, result
    end
  end

  def test_a_second_caller_waits_while_the_only_slot_is_held
    Dir.mktmpdir do |dir|
      held = Queue.new
      release = Queue.new
      entered_second = false

      holder = Thread.new do
        WPGSA::Slot.acquire(1, dir: dir) do
          held << true
          release.pop
        end
      end

      begin
        Timeout.timeout(5) { held.pop }
      rescue Timeout::Error
        flunk "holder thread never signaled that it entered the slot"
      end

      waiter = Thread.new do
        WPGSA::Slot.acquire(1, dir: dir, poll: 0.05) { entered_second = true }
      end

      sleep 0.3
      refute entered_second, "second caller entered while the slot was held"

      release << true
      holder.join
      waiter.join(5)
      assert entered_second, "second caller never entered after release"
    end
  end

  def test_raises_for_a_non_positive_limit
    Dir.mktmpdir do |dir|
      assert_raises(ArgumentError) do
        WPGSA::Slot.acquire(0, dir: dir) { :never }
      end
    end
  end
end
