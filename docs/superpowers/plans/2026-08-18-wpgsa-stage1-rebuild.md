# wpgsa.org 第1段階 再構築 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** サポート内の OS と依存関係の上で `wpgsa.org` を動かし、混在コンテンツによる機能停止と 26 件の脆弱性を解消する。

**Architecture:** Amazon Linux 2023 上に nginx と Puma を置き、Sinatra アプリを systemd で動かす。解析は既存の `inutano/wpgsa:0.5.2` を `docker run` で呼ぶ。アップロードは 202 を返して切り離したランナーが処理し、クライアントがポーリングする。切り替えは ALB のターゲット登録の差し替えのみで行い、DNS と証明書は触らない。

**Tech Stack:** Ruby 3.2 以上、Sinatra 4.2.1、Puma 8.0.2、Haml 7.4.1、nginx、Docker、systemd、Amazon Linux 2023、ALB、CloudWatch、SNS、DLM

**Spec:** [docs/superpowers/specs/2026-08-18-wpgsa-stage1-rebuild-design.md](../specs/2026-08-18-wpgsa-stage1-rebuild-design.md)

**Branch:** `stage1-rebuild`（`origin/master` = `0e81e96` から分岐済み）

## Global Constraints

すべてのタスクの要件に、以下が暗黙に含まれる。

- **ローカルの Ruby**: `/usr/bin/ruby` は 2.6.10 で使えない。すべての ruby / bundle / gem コマンドは `export PATH=/opt/homebrew/opt/ruby/bin:$PATH` を先に実行する（Ruby 4.0.5）。
- **Ruby 下限**: `Gemfile` に `ruby '>= 3.2'`。`haml` 7.4.1 が 3.2.0 以上を要求するため。
- **本番の直接依存は 4 gem のみ**: `sinatra` / `puma` / `haml` / `rake`。テスト用 gem は `group :test` に置き、本番は `bundle config set --local without test` で除外する。
- **必須バージョン下限**（Dependabot 26 件の解消条件）: `rack` >= 3.1.21、`rack-session` >= 2.1.2、`sinatra` >= 4.2.0。`webrick` は依存から消えること。
- **アーキテクチャは x86_64 固定**: `inutano/wpgsa:0.5.2` が amd64 専用のため。
- **AWS**: profile は `riken`、region は `ap-northeast-1`。すべての aws コマンドに `--profile riken --region ap-northeast-1` を付ける。
- **既存 AWS 資源の ID**: ALB `wpgsa-ELB`、ターゲットグループ ARN `arn:aws:elasticloadbalancing:ap-northeast-1:463278513270:targetgroup/wpgsa-TG/84fe8f99ed28c72a`、EC2 の SG `sg-0afcd77f843b6a2b0`、ALB の SG `sg-0e6d9de4c608c5de8`、旧インスタンス `i-0650fe6a3ca5f5b4d`、サブネット `subnet-098154d5afe513288`、VPC `vpc-012b8ad40d152e0e8`。
- **解析結果データは移行しない**。`example` のみ引き継ぐ。過去の `/result?uuid=...` は失効する。
- **順序の制約**: ALB 80 番のリダイレクト化（Task 13）は、受け入れ基準 1（HTTPS で CSS/JS が読める）を満たしたことを確認してから行う。逆順にすると壊れた HTTPS へ利用者を強制することになる。

## ファイル構成

| ファイル | 役割 | 操作 |
|---|---|---|
| `Gemfile` / `Gemfile.lock` | 依存定義 | 変更 |
| `.ruby-version` | Ruby バージョン記録 | 新規 |
| `config.ru` | Rack エントリポイント | 変更 |
| `config/puma.rb` | Puma 設定 | 新規 |
| `app.rb` | ルーティング | 変更 |
| `lib/wpgsa.rb` | 名前空間、ID 検証 | 変更 |
| `lib/wpgsa/docker.rb` | 解析コンテナ起動 | 変更 |
| `lib/wpgsa/job.rb` | ジョブ状態管理 | 変更 |
| `lib/wpgsa/result.rb` | 結果ファイル読み出し | 変更 |
| `lib/wpgsa/slot.rb` | 同時実行数の制限 | 新規 |
| `lib/tasks/init.rake` | 初期化タスク | 変更 |
| `script/run-job` | ジョブ実行本体 | 変更 |
| `script/cleanup-jobs` | 古いジョブの削除 | 新規 |
| `script/bootstrap-wpgsa-instance.sh` | ホスト構築 | 変更 |
| `script/launch-wpgsa-ec2.sh` | インスタンス起動 | 変更 |
| `public/css/wpgsa.css` | 変換済みスタイル | 新規 |
| `views/*.haml` | テンプレート（CSS 参照先） | 変更 |
| `test/test_helper.rb` | テスト共通設定 | 新規 |
| `test/test_data_id.rb` | ID 検証のテスト | 新規 |
| `test/test_docker.rb` | コマンド組み立てのテスト | 新規 |
| `test/test_slot.rb` | 同時実行制限のテスト | 新規 |
| `test/test_app.rb` | エンドポイントのテスト | 新規 |
| `Rakefile` | テストタスク追加 | 変更 |
| `.gitignore` | example の追跡 | 変更 |

---

## Phase 1: アプリケーション層

### Task 1: 非同期実装の取り込みとテスト基盤の導入

設計書はテストに触れていないが、以降のタスクが振る舞いを変えるため、先にテストを走らせる土台を作る。

**Files:**
- Modify: `Gemfile`
- Create: `.ruby-version`, `test/test_helper.rb`, `test/test_smoke.rb`
- Modify: `Rakefile`

**Interfaces:**
- Produces: `test/test_helper.rb` が `APP_ROOT` 定数と Minitest の設定を提供する。以降のテストはすべて `require_relative "test_helper"` で始める。

- [ ] **Step 1: 非同期実装をマージする**

```bash
cd /Users/inutano/repos/wpgsa.org
git switch stage1-rebuild
git merge --no-ff async-job-processing -m "Merge asynchronous job processing into stage 1 rebuild"
```

衝突しないことは確認済み。`lib/wpgsa/job.rb` と `script/run-job` が追加され、`app.rb` に `GET /wpgsa/job` が入る。

- [ ] **Step 2: Ruby バージョンを固定する**

`.ruby-version` を新規作成:

```
3.4
```

- [ ] **Step 3: Gemfile にテストグループを足す**

`Gemfile` を以下の内容に置き換える（本番依存の刷新は Task 2 で行うため、ここでは `group :test` の追加のみ）:

```ruby
source 'https://rubygems.org'

ruby '>= 3.2'

gem 'sinatra'
gem 'rake'
gem 'haml'
gem 'sass'
gem 'redcarpet'
gem 'rack-protection'
gem 'rackup'

group :test do
  gem 'minitest'
  gem 'rack-test'
end
```

- [ ] **Step 4: bundle install する**

```bash
export PATH=/opt/homebrew/opt/ruby/bin:$PATH
bundle install
```

期待: 成功し `Gemfile.lock` に `minitest` と `rack-test` が入る。

- [ ] **Step 5: テストヘルパを書く**

`test/test_helper.rb` を新規作成:

```ruby
require "bundler/setup"
require "minitest/autorun"

APP_ROOT = File.expand_path("..", __dir__)

$LOAD_PATH.unshift(APP_ROOT)
$LOAD_PATH.unshift(File.join(APP_ROOT, "lib"))
```

- [ ] **Step 6: 落ちるスモークテストを書く**

`test/test_smoke.rb` を新規作成:

```ruby
require_relative "test_helper"
require "lib/wpgsa"

class TestSmoke < Minitest::Test
  def test_wpgsa_module_is_defined
    assert defined?(WPGSA)
  end

  def test_job_class_is_loaded
    assert defined?(WPGSA::Job)
  end
end
```

- [ ] **Step 7: Rakefile にテストタスクを足す**

`Rakefile` を以下に置き換える。既存の `require './app'` は Sinatra の読み込みを伴い、テストタスクの実行には不要なので外す:

```ruby
require "rake/testtask"

PROJ_ROOT = File.expand_path(__dir__)

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.libs << "."
  t.test_files = FileList["test/test_*.rb"]
  t.warning = false
end

Dir["#{PROJ_ROOT}/lib/tasks/**/*.rake"].each do |path|
  load path
end

task default: :test
```

`lib/tasks/init.rake` は `PROJ_ROOT` を参照するため、定義の順序を保つこと。

- [ ] **Step 8: テストを走らせて通ることを確認する**

```bash
export PATH=/opt/homebrew/opt/ruby/bin:$PATH
bundle exec rake test
```

期待: 2 runs, 0 failures, 0 errors

- [ ] **Step 9: commit**

```bash
git add Gemfile Gemfile.lock .ruby-version Rakefile test/
git commit -m "Add minitest harness and pin Ruby version"
```

---

### Task 2: 依存関係の刷新

**Files:**
- Modify: `Gemfile`, `Gemfile.lock`, `config.ru`, `app.rb`, `views/*.haml`
- Create: `config/puma.rb`, `public/css/wpgsa.css`
- Delete: なし（`views/style.sass` は変換元として残す）

**Interfaces:**
- Consumes: Task 1 のテスト基盤
- Produces: `public/css/wpgsa.css` を全テンプレートが `#{app_root}/css/wpgsa.css` で参照する。`get "/:source.css"` ルートは存在しなくなる。

- [ ] **Step 1: style.sass を CSS に変換する**

削除する前に、現行の sass gem で一度だけ変換する:

```bash
export PATH=/opt/homebrew/opt/ruby/bin:$PATH
mkdir -p public/css
bundle exec ruby -e '
require "sass"
src = File.read("views/style.sass")
css = Sass::Engine.new(src, syntax: :sass).render
File.write("public/css/wpgsa.css", css)
puts "wrote #{css.bytesize} bytes"
'
```

期待: `wrote 1082 bytes`。本番が現在配信している `/style.css` と同じ大きさであること。

- [ ] **Step 2: テンプレートの参照先を差し替える**

```bash
sed -i '' 's|#{app_root}/style.css|#{app_root}/css/wpgsa.css|g' views/*.haml
grep -n "wpgsa.css" views/*.haml
```

期待: 5 ファイル（`index` `download` `result` `heatmap` `not_found`）すべてに 1 行ずつ出る。0 件のファイルがあれば手で確認する。

- [ ] **Step 3: sass ルートを削除する**

`app.rb` から以下の 3 行を削除する:

```ruby
  get "/:source.css" do
    sass params[:source].intern
  end
```

同じく `app.rb` の `require 'sass'` を削除する。

- [ ] **Step 4: Gemfile を最終形にする**

```ruby
source 'https://rubygems.org'

ruby '>= 3.2'

gem 'sinatra'
gem 'puma'
gem 'haml'
gem 'rake'

group :test do
  gem 'minitest'
  gem 'rack-test'
end
```

- [ ] **Step 5: config.ru から rack-protection の明示 require を外す**

`config.ru` を以下に置き換える。Sinatra が `Rack::Protection` を自前で組み込むため、明示的な読み込みは不要:

```ruby
require "bundler/setup"
Bundler.require(:default)

require File.expand_path("app", __dir__)
run WpgsaApp
```

- [ ] **Step 6: Puma 設定を書く**

`config/puma.rb` を新規作成:

```ruby
app_root = File.expand_path("..", __dir__)

directory app_root
environment ENV.fetch("RACK_ENV", "production")

threads_count = Integer(ENV.fetch("PUMA_THREADS", "5"))
threads threads_count, threads_count

workers Integer(ENV.fetch("PUMA_WORKERS", "2"))
preload_app!

bind ENV.fetch("PUMA_BIND", "unix://#{app_root}/tmp/sockets/puma.sock")

pidfile "#{app_root}/tmp/pids/puma.pid"
state_path "#{app_root}/tmp/pids/puma.state"

on_restart do
  require "fileutils"
  FileUtils.mkdir_p("#{app_root}/tmp/sockets")
  FileUtils.mkdir_p("#{app_root}/tmp/pids")
end
```

- [ ] **Step 7: lock を作り直して依存を検証する**

```bash
export PATH=/opt/homebrew/opt/ruby/bin:$PATH
rm -f Gemfile.lock
bundle lock --add-platform x86_64-linux
bundle install
bundle list | grep -E "rack |rack-session|sinatra|puma|haml|webrick|sass|redcarpet"
```

期待: `rack (3.2.7)` 以上、`rack-session (2.1.2)` 以上、`sinatra (4.2.1)` 以上、`puma`、`haml (7.4.1)` が出る。`webrick` `sass` `redcarpet` は 1 件も出ない。

- [ ] **Step 8: 脆弱性が消えたことを確認する**

```bash
export PATH=/opt/homebrew/opt/ruby/bin:$PATH
gem install bundler-audit --no-document
bundle exec bundler-audit check --update
```

期待: `No vulnerabilities found`

- [ ] **Step 9: テストが通ることを確認する**

```bash
bundle exec rake test
```

期待: 2 runs, 0 failures, 0 errors

- [ ] **Step 10: commit**

```bash
git add Gemfile Gemfile.lock config.ru config/puma.rb app.rb views/ public/css/wpgsa.css
git commit -m "Replace Ruby Sass with a precompiled stylesheet and move to Puma

Drops sass, redcarpet, rack-protection and rackup as direct dependencies.
Ruby Sass has been unmaintained since 2019 and pulled in ffi, which
required a compiler on the deployment host for a 1082 byte stylesheet
that never changes. Precompiling it removes five gems and the
get /:source.css route, which returned 500 for any unknown name.

The remaining set resolves to rack 3.2.7, rack-session 2.1.2 and
sinatra 4.2.1, clearing all 26 open Dependabot alerts. webrick leaves
the dependency graph entirely."
```

---

### Task 3: UUID 検証によるパストラバーサルの修正

CodeQL の未解決警告 `rb/path-injection`（`lib/wpgsa/result.rb:63`）を閉じる。

**Files:**
- Modify: `lib/wpgsa.rb`, `lib/wpgsa/job.rb`, `lib/wpgsa/result.rb`, `app.rb`
- Test: `test/test_data_id.rb`

**Interfaces:**
- Produces: `WPGSA.valid_data_id?(id)` が真偽値を返す。`WPGSA::InvalidDataId < StandardError` を `Job.load` と `Result.new` が不正な id に対して送出する。

- [ ] **Step 1: 落ちるテストを書く**

`test/test_data_id.rb` を新規作成:

```ruby
require_relative "test_helper"
require "lib/wpgsa"

class TestDataId < Minitest::Test
  VALID = "d5767493-4b86-4297-8b8f-d650f413d952"

  def test_accepts_a_uuid
    assert WPGSA.valid_data_id?(VALID)
  end

  def test_accepts_the_example_id
    assert WPGSA.valid_data_id?("example")
  end

  def test_rejects_nil
    refute WPGSA.valid_data_id?(nil)
  end

  def test_rejects_empty_string
    refute WPGSA.valid_data_id?("")
  end

  def test_rejects_parent_directory_traversal
    refute WPGSA.valid_data_id?("../../etc")
  end

  def test_rejects_a_uuid_with_a_traversal_suffix
    refute WPGSA.valid_data_id?("#{VALID}/../../etc")
  end

  def test_rejects_uppercase_uuid
    refute WPGSA.valid_data_id?(VALID.upcase)
  end

  def test_rejects_a_uuid_with_a_trailing_newline
    refute WPGSA.valid_data_id?("#{VALID}\n")
  end

  def test_job_load_raises_on_an_invalid_id
    assert_raises(WPGSA::InvalidDataId) { WPGSA::Job.load("../../etc") }
  end

  def test_result_new_raises_on_an_invalid_id
    assert_raises(WPGSA::InvalidDataId) { WPGSA::Result.new("../../etc", "p-value") }
  end
end
```

`\n` を拒否するテストを入れているのは、Ruby の正規表現で `$` や `\Z` を使うと末尾の改行を許してしまうためである。`\z` を使う根拠をテストで固定する。

- [ ] **Step 2: テストが落ちることを確認する**

```bash
export PATH=/opt/homebrew/opt/ruby/bin:$PATH
bundle exec rake test TEST=test/test_data_id.rb
```

期待: `NoMethodError: undefined method 'valid_data_id?'` で失敗する。

- [ ] **Step 3: 検証を実装する**

`lib/wpgsa.rb` を以下に置き換える:

```ruby
require 'wpgsa/docker'
require 'wpgsa/job'
require 'wpgsa/result'

module WPGSA
  class InvalidDataId < StandardError; end

  UUID_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  EXAMPLE_ID = "example".freeze

  def self.valid_data_id?(id)
    return false unless id.is_a?(String)
    return true if id == EXAMPLE_ID

    UUID_PATTERN.match?(id)
  end

  def self.validate_data_id!(id)
    raise InvalidDataId, "invalid data id" unless valid_data_id?(id)

    id
  end
end
```

`wpgsa/slot` の require は Task 5 で追加する。この時点ではファイルが無いため、ここで書くと `LoadError` になる。

- [ ] **Step 4: Job.load に検証を入れる**

`lib/wpgsa/job.rb` の `self.load` の冒頭に 1 行足す:

```ruby
    def self.load(uuid)
      WPGSA.validate_data_id!(uuid)
      data_dir = File.join(__dir__, "../../public/data", uuid)
```

- [ ] **Step 5: Result に検証を入れる**

`lib/wpgsa/result.rb` の `initialize` の冒頭に 1 行足す:

```ruby
    def initialize(uuid, type)
      WPGSA.validate_data_id!(uuid)
      @uuid = uuid
```

- [ ] **Step 6: テストが通ることを確認する**

```bash
bundle exec rake test TEST=test/test_data_id.rb
```

期待: 10 runs, 0 failures, 0 errors

- [ ] **Step 7: app.rb で 404 に変換する**

`app.rb` の `GET /wpgsa/job` の rescue 節に `WPGSA::InvalidDataId` を足す:

```ruby
  get "/wpgsa/job" do
    content_type "application/json"
    job = WPGSA::Job.load(params[:uuid])
    JSON.dump(job.metadata)
  rescue WPGSA::InvalidDataId, Errno::ENOENT, JSON::ParserError
    status 404
    JSON.dump({
      "uuid" => params[:uuid],
      "status" => "unknown",
      "error_message" => "Job not found"
    })
  end
```

`GET /wpgsa/result` にも rescue を足す:

```ruby
  get "/wpgsa/result" do
    uuid = params[:uuid]
    type = params[:type]
    result = WPGSA::Result.new(uuid, type)
    case params[:format]
    when "tsv"
      result.read
    when "filepath"
      result.result_file_path.sub(/^.+public/,"")
    else
      content_type "application/json"
      result.to_json
    end
  rescue WPGSA::InvalidDataId
    status 404
    content_type "application/json"
    JSON.dump({ "error_message" => "Not found" })
  end
```

- [ ] **Step 8: commit**

```bash
git add lib/wpgsa.rb lib/wpgsa/job.rb lib/wpgsa/result.rb app.rb test/test_data_id.rb
git commit -m "Validate data ids before using them in paths

Job.load and Result took params[:uuid] straight into File.join against
public/data, so a crafted uuid escaped the data directory. Both now
reject anything that is not a lowercase UUID or the literal example id,
and the endpoints turn that into a 404.

Closes the open CodeQL rb/path-injection alert on result.rb."
```

---

### Task 4: コマンドインジェクションの修正

アプリプロセスが docker グループに属する構成なので、ここは権限昇格に直結しうる。

**Files:**
- Modify: `lib/wpgsa/docker.rb`
- Test: `test/test_docker.rb`

**Interfaces:**
- Produces: `WPGSA::Docker#wpgsa_command` と `#hclust_command(t_score)` が、シェルを経由しない引数配列を返す。`WPGSA::AnalysisFailed < StandardError` を実行失敗時に送出する。

- [ ] **Step 1: 落ちるテストを書く**

`test/test_docker.rb` を新規作成:

```ruby
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
    cmd = build(input_data: 'a"; rm -rf /; echo "b')
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
```

- [ ] **Step 2: テストが落ちることを確認する**

```bash
export PATH=/opt/homebrew/opt/ruby/bin:$PATH
bundle exec rake test TEST=test/test_docker.rb
```

期待: `NoMethodError: undefined method 'wpgsa_command'` で失敗する。

- [ ] **Step 3: コマンド組み立てを分離して実装する**

`lib/wpgsa/docker.rb` の `run_wpgsa`、`run_hclust`、`wpgsa_results`、`dry_run` を以下で置き換える。
`wpgsa_results` と `dry_run` は非同期化によって呼ばれなくなった死んだコードなので削除する:

```ruby
    def wpgsa_command
      [
        "docker", "run", "--rm", "-i",
        "-v", "#{@workdir}:/data",
        wpgsa_container_id, "wpgsa",
        "--logfc-file", "/data/#{@input_data}",
        "--network-file", "/data/#{@network_file}"
      ]
    end

    def hclust_command(t_score)
      [
        "docker", "run", "--rm", "-i",
        "-v", "#{@workdir}:/data",
        wpgsa_container_id, "hclust",
        "/data/#{t_score}"
      ]
    end

    def run_wpgsa
      raise AnalysisFailed, "wpgsa container exited non-zero" unless system(*wpgsa_command)
    end

    def run_hclust
      t_score_path = Dir.glob(File.join(@workdir, "*t_score*")).first
      return if !t_score_path

      # 1 サンプルのみの入力ではクラスタリング結果が出ないため、
      # 失敗しても解析全体は成功として扱う
      File.open(File.join(@workdir, "data.hclust.js"), "w") do |out|
        system(*hclust_command(File.basename(t_score_path)), out: out)
      end
    end
```

`lib/wpgsa.rb` に例外クラスを足す:

```ruby
  class AnalysisFailed < StandardError; end
```

- [ ] **Step 4: テストが通ることを確認する**

```bash
bundle exec rake test TEST=test/test_docker.rb
```

期待: 6 runs, 0 failures, 0 errors

- [ ] **Step 5: 全テストが通ることを確認する**

```bash
bundle exec rake test
```

期待: 18 runs, 0 failures, 0 errors

- [ ] **Step 6: commit**

```bash
git add lib/wpgsa/docker.rb lib/wpgsa.rb test/test_docker.rb
git commit -m "Run the analysis container without a shell

run_wpgsa and run_hclust interpolated the uploaded filename into a
string and executed it with backticks. staging_input_data only replaces
whitespace, so quotes and dollar signs survived into the shell. The app
user is in the docker group, which makes that a privilege escalation
path.

Both now pass an argument array to system(), and run_hclust captures
stdout through the :out option instead of a shell redirect.

Also drops wpgsa_results and dry_run, which nothing calls since the
upload path became asynchronous."
```

---

### Task 5: 同時実行数の制限

t3.small のメモリは 2 GiB で、解析が重なると不足する。

**Files:**
- Create: `lib/wpgsa/slot.rb`
- Modify: `lib/wpgsa.rb`, `lib/wpgsa/job.rb`, `config.yaml`
- Test: `test/test_slot.rb`

**Interfaces:**
- Consumes: なし
- Produces: `WPGSA::Slot.acquire(limit, dir:, poll:) { ... }` がスロットを取れるまでブロックし、取れたらブロックを実行して戻り値を返す。

- [ ] **Step 1: 落ちるテストを書く**

`test/test_slot.rb` を新規作成:

```ruby
require_relative "test_helper"
require "lib/wpgsa"
require "tmpdir"

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

      held.pop
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
end
```

- [ ] **Step 2: テストが落ちることを確認する**

```bash
export PATH=/opt/homebrew/opt/ruby/bin:$PATH
bundle exec rake test TEST=test/test_slot.rb
```

期待: `NameError: uninitialized constant WPGSA::Slot` で失敗する。

- [ ] **Step 3: Slot を実装する**

`lib/wpgsa/slot.rb` を新規作成:

```ruby
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
```

`lib/wpgsa.rb` に `require 'wpgsa/slot'` を足す（Task 3 の Step 3 で保留していた行）。

- [ ] **Step 4: テストが通ることを確認する**

```bash
bundle exec rake test TEST=test/test_slot.rb
```

期待: 4 runs, 0 failures, 0 errors

- [ ] **Step 5: Job#run! でスロットを取る**

`lib/wpgsa/job.rb` の `run!` を以下に置き換える。`queued` のまま待たせるため、
スロットを取ってから `running` に遷移させる:

```ruby
    def run!(concurrency: 2)
      WPGSA::Slot.acquire(concurrency) do
        write_metadata(
          "status" => "running",
          "started_at" => timestamp,
          "error_message" => nil
        )

        docker = WPGSA::Docker.from_job(
          @uuid,
          @workdir,
          @data_dir,
          @input_filename,
          @network_file
        )

        result_paths = docker.run_analysis
        write_metadata(
          "status" => "finished",
          "finished_at" => timestamp,
          "result_paths" => result_paths
        )
      end
    rescue StandardError => e
      write_metadata(
        "status" => "failed",
        "finished_at" => timestamp,
        "error_message" => e.message,
        "result_paths" => []
      )
      raise
    end
```

- [ ] **Step 6: 設定値を通す**

`config.yaml` に上限を足す（`network_file_path` の修正は Task 6 で行う）:

```yaml
max_concurrent_jobs: 2
```

`script/run-job` を以下に置き換える:

```ruby
#!/usr/bin/env ruby

$LOAD_PATH << File.expand_path("..", __dir__)
$LOAD_PATH << File.expand_path("../lib", __dir__)

require "yaml"
require "lib/wpgsa"

uuid = ARGV[0]
abort("missing uuid") if !uuid || uuid.empty?

config_path = File.expand_path("../config.yaml", __dir__)
config = File.exist?(config_path) ? YAML.load_file(config_path) : {}
concurrency = Integer(config["max_concurrent_jobs"] || 2)

job = WPGSA::Job.load(uuid)
job.run!(concurrency: concurrency)
```

- [ ] **Step 7: 全テストが通ることを確認する**

```bash
bundle exec rake test
```

期待: 22 runs, 0 failures, 0 errors

- [ ] **Step 8: commit**

```bash
git add lib/wpgsa/slot.rb lib/wpgsa.rb lib/wpgsa/job.rb script/run-job config.yaml test/test_slot.rb
git commit -m "Cap concurrent analysis runs

Job#spawn! detached runners without limit. Two concurrent analyses on a
t3.small exhaust its 2 GiB and the OOM killer takes whichever process it
finds, including Puma.

Runners now take one of a fixed number of file locks before moving the
job to running, so surplus jobs sit in queued until a slot frees. The
client already polls on queued, so no interface changes."
```

---

### Task 6: 設定の不整合修正と Example データの追跡

**Files:**
- Modify: `config.yaml`, `lib/tasks/init.rake`, `.gitignore`
- Add: `public/data/example/` (5 ファイル)

- [ ] **Step 1: 存在しないネットワークファイル名を直す**

`config.yaml` を以下に置き換える。実在するのは `merged_mouse_150904_trim.network` である:

```yaml
workdir: "/tmp/wpgsa"
network_file_path: "./data/merged_mouse_150904_trim.network" # rake wpgsa:init が絶対パスに書き換える
max_concurrent_jobs: 2
```

`lib/tasks/init.rake` の該当行を直す:

```ruby
    updated = content.sub(/^network_file_path.+$/, "network_file_path: #{File.join(PROJ_ROOT, "data/merged_mouse_150904_trim.network")}")
```

- [ ] **Step 2: 実在を確認する**

```bash
ls -la data/merged_mouse_150904_trim.network
grep -rn "merged_mouse_v7_160212" . --exclude-dir=.git || echo "存在しないファイル名への参照はなくなった"
```

期待: ファイルが存在し、`merged_mouse_v7_160212` への参照が 0 件。

- [ ] **Step 3: .gitignore を書き換える**

`.gitignore` の末尾にある `public/data` の行を、以下の 2 行に置き換える:

```
public/data/*
!public/data/example/
```

`public/data` のままでは配下の例外が効かないことは検証済み。

- [ ] **Step 4: example が追跡対象になり、他が除外されたままか確認する**

```bash
git status --porcelain --untracked-files=all public/data | head
```

期待: `?? public/data/example/...` が 5 行出る。他の UUID ディレクトリがあれば出ないこと。

- [ ] **Step 5: example を追加する**

```bash
git add -f public/data/example
git status --porcelain public/data
```

期待: `A  public/data/example/` 配下の 5 ファイル。

- [ ] **Step 6: commit**

```bash
git add config.yaml lib/tasks/init.rake .gitignore public/data/example
git commit -m "Track the example dataset and fix the network file path

config.yaml and init.rake both pointed at merged_mouse_v7_160212.network,
which does not exist in the repository; the file shipped is
merged_mouse_150904_trim.network. Running rake wpgsa:init wrote a broken
path.

public/data was ignored as a directory, so the example results could not
be re-included and every fresh host served a broken View Example Data
page. Ignoring public/data/* instead lets the example directory be
tracked while real job output stays out."
```

---

### Task 7: 古いジョブの掃除

`public/data` と `/tmp/wpgsa` にジョブが残り続け、ディスクが単調に増える。

**Files:**
- Create: `script/cleanup-jobs`
- Test: `test/test_cleanup.rb`

**Interfaces:**
- Produces: `script/cleanup-jobs` が環境変数 `WPGSA_DATA_DIR`、`WPGSA_WORKDIR`、`WPGSA_RETENTION_DAYS` を読んで古いディレクトリを削除する。

- [ ] **Step 1: 落ちるテストを書く**

`test/test_cleanup.rb` を新規作成:

```ruby
require_relative "test_helper"
require "tmpdir"
require "fileutils"

class TestCleanupJobs < Minitest::Test
  SCRIPT = File.join(APP_ROOT, "script", "cleanup-jobs")

  def make_dir(root, name, age_days)
    path = File.join(root, name)
    FileUtils.mkdir_p(path)
    File.write(File.join(path, "job.json"), "{}")
    t = Time.now - age_days * 86_400
    File.utime(t, t, path)
    path
  end

  def run_cleanup(data_dir, workdir, days)
    system(
      { "WPGSA_DATA_DIR" => data_dir,
        "WPGSA_WORKDIR" => workdir,
        "WPGSA_RETENTION_DAYS" => days.to_s },
      RbConfig.ruby, SCRIPT,
      out: File::NULL
    )
  end

  def test_removes_directories_older_than_the_retention_period
    Dir.mktmpdir do |data_dir|
      Dir.mktmpdir do |workdir|
        old = make_dir(data_dir, "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", 40)
        assert run_cleanup(data_dir, workdir, 30)
        refute File.exist?(old)
      end
    end
  end

  def test_keeps_directories_inside_the_retention_period
    Dir.mktmpdir do |data_dir|
      Dir.mktmpdir do |workdir|
        fresh = make_dir(data_dir, "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", 3)
        assert run_cleanup(data_dir, workdir, 30)
        assert File.exist?(fresh)
      end
    end
  end

  def test_never_removes_the_example_directory
    Dir.mktmpdir do |data_dir|
      Dir.mktmpdir do |workdir|
        example = make_dir(data_dir, "example", 4000)
        assert run_cleanup(data_dir, workdir, 30)
        assert File.exist?(example), "example must survive cleanup"
      end
    end
  end

  def test_cleans_the_work_directory_too
    Dir.mktmpdir do |data_dir|
      Dir.mktmpdir do |workdir|
        old = make_dir(workdir, "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", 40)
        assert run_cleanup(data_dir, workdir, 30)
        refute File.exist?(old)
      end
    end
  end
end
```

- [ ] **Step 2: テストが落ちることを確認する**

```bash
export PATH=/opt/homebrew/opt/ruby/bin:$PATH
bundle exec rake test TEST=test/test_cleanup.rb
```

期待: `script/cleanup-jobs` が存在せず失敗する。

- [ ] **Step 3: 掃除スクリプトを書く**

`script/cleanup-jobs` を新規作成:

```ruby
#!/usr/bin/env ruby

require "fileutils"

KEEP = ["example"].freeze

data_dir = ENV["WPGSA_DATA_DIR"] || File.expand_path("../public/data", __dir__)
workdir  = ENV["WPGSA_WORKDIR"]  || "/tmp/wpgsa"
days     = Integer(ENV["WPGSA_RETENTION_DAYS"] || "30")

cutoff = Time.now - days * 86_400
removed = 0

[data_dir, workdir].each do |root|
  next unless File.directory?(root)

  Dir.children(root).each do |name|
    next if KEEP.include?(name)

    path = File.join(root, name)
    next unless File.directory?(path)
    next if File.mtime(path) > cutoff

    FileUtils.rm_rf(path)
    removed += 1
  end
end

puts "removed #{removed} job director#{removed == 1 ? "y" : "ies"} older than #{days} days"
```

実行権限を付ける:

```bash
chmod +x script/cleanup-jobs
```

- [ ] **Step 4: テストが通ることを確認する**

```bash
bundle exec rake test TEST=test/test_cleanup.rb
```

期待: 4 runs, 0 failures, 0 errors

- [ ] **Step 5: 全テストが通ることを確認する**

```bash
bundle exec rake test
```

期待: 26 runs, 0 failures, 0 errors

- [ ] **Step 6: commit**

```bash
git add script/cleanup-jobs test/test_cleanup.rb
git commit -m "Add a retention sweep for finished jobs

Nothing removed job output, so public/data and the work directory grew
without bound on a 30 GiB root volume. Removes job directories older
than the retention window from both, keeping the example dataset
unconditionally."
```

---

### Task 8: エンドポイントのテスト

ここまでの変更がルーティングを壊していないことを、リクエスト単位で固定する。

**Files:**
- Create: `test/test_app.rb`

- [ ] **Step 1: テストを書く**

`test/test_app.rb` を新規作成:

```ruby
require_relative "test_helper"
require "rack/test"
require "app"

class TestApp < Minitest::Test
  include Rack::Test::Methods

  def app
    WpgsaApp
  end

  def test_index_renders
    get "/"
    assert last_response.ok?
    assert_includes last_response.body, "wPGSA"
  end

  def test_index_uses_the_forwarded_scheme_for_assets
    get "/", {}, { "HTTP_X_FORWARDED_PROTO" => "https", "HTTP_HOST" => "wpgsa.org" }
    assert_includes last_response.body, "https://wpgsa.org/css/wpgsa.css"
    refute_includes last_response.body, "http://wpgsa.org/css/"
  end

  def test_download_renders
    get "/download"
    assert last_response.ok?
  end

  def test_unknown_path_renders_the_404_page
    get "/no-such-page"
    assert_equal 404, last_response.status
  end

  def test_unknown_css_is_not_a_server_error
    get "/nosuchstylesheet.css"
    assert_equal 404, last_response.status
  end

  def test_job_status_rejects_a_traversal_id
    get "/wpgsa/job", { uuid: "../../etc" }
    assert_equal 404, last_response.status
  end

  def test_result_rejects_a_traversal_id
    get "/wpgsa/result", { uuid: "../../etc", type: "p-value", format: "tsv" }
    assert_equal 404, last_response.status
  end

  def test_upload_without_a_file_does_not_return_an_empty_200
    post "/wpgsa/result"
    refute_equal 200, last_response.status
  end
end
```

- [ ] **Step 2: テストを走らせ、落ちるものを確認する**

```bash
export PATH=/opt/homebrew/opt/ruby/bin:$PATH
bundle exec rake test TEST=test/test_app.rb
```

期待: `test_upload_without_a_file_does_not_return_an_empty_200` が失敗する。
`params[:file]` が無いとき `if` が nil を返し、Sinatra が 200 と空ボディを返すため。
他は通る。

- [ ] **Step 3: 設定ファイルの読み込みを絶対パスにする**

`app.rb` の `configure` ブロックは `YAML.load_file("./config.yaml")` と書いており、
プロセスの作業ディレクトリに依存する。
`__dir__` 基準に変える:

```ruby
  configure do
    set :config, YAML.load_file(File.expand_path("config.yaml", __dir__))
  end
```

- [ ] **Step 4: ファイル無しの POST を 400 にする**

`app.rb` の `post "/wpgsa/result"` を以下に置き換える:

```ruby
  post "/wpgsa/result" do
    content_type "application/json"

    if !params[:file]
      status 400
      return JSON.dump({ "error_message" => "No file was uploaded" })
    end

    workdir = settings.config["workdir"]
    network_file_path = settings.config["network_file_path"]
    job = WPGSA::Job.create(params[:file], workdir, network_file_path)
    job.spawn!

    status 202
    JSON.dump({
      "uuid" => job.uuid,
      "status" => "queued"
    })
  end
```

- [ ] **Step 5: テストが通ることを確認する**

```bash
bundle exec rake test TEST=test/test_app.rb
```

期待: 8 runs, 0 failures, 0 errors

- [ ] **Step 6: 全テストが通ることを確認する**

```bash
bundle exec rake test
```

期待: 34 runs, 0 failures, 0 errors

- [ ] **Step 7: commit**

```bash
git add test/test_app.rb app.rb
git commit -m "Cover the endpoints with request tests

Pins the behaviour the rebuild depends on: assets follow
X-Forwarded-Proto, an unknown .css name is a 404 rather than the 500 the
sass route used to raise, and traversal ids are rejected at the HTTP
boundary.

A POST with no file returned 200 with an empty body, which the client
reported as a generic failure. It is now a 400 with a message.

config.yaml was loaded through a working-directory-relative path, so the
app only booted from the project root. It now resolves against __dir__."
```

---

## Phase 2: ホスト構築

### Task 9: bootstrap スクリプトの書き換え

**Files:**
- Modify: `script/bootstrap-wpgsa-instance.sh`

**Interfaces:**
- Produces: 冪等な bootstrap。`nginx` → unix socket → Puma、`wpgsa.service`、`wpgsa-cleanup.timer`、swap、`public/data/example` の配置を行う。

- [ ] **Step 1: パッケージ導入部を Ruby バージョン検証つきに変える**

`script/bootstrap-wpgsa-instance.sh` の `install_packages` を以下に置き換える:

```bash
RUBY_PKG="${RUBY_PKG:-}"

detect_ruby_package() {
  local candidate
  for candidate in ruby3.4 ruby3.3 ruby3.2; do
    if dnf list --available "$candidate" >/dev/null 2>&1 || dnf list --installed "$candidate" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

install_packages() {
  log "installing OS packages"
  retry dnf makecache

  if [ -z "$RUBY_PKG" ]; then
    RUBY_PKG="$(detect_ruby_package)" || {
      log "no ruby3.2 or newer package is available on this AMI"
      exit 1
    }
  fi
  log "using ruby package: $RUBY_PKG"

  retry dnf install -y \
    git nginx docker "$RUBY_PKG" "${RUBY_PKG}-devel" \
    gcc gcc-c++ make patch openssl-devel zlib-devel libffi-devel \
    redhat-rpm-config tar gzip which procps-ng jq findutils shadow-utils

  local version
  version="$(ruby -e 'print RUBY_VERSION')"
  case "$version" in
    3.2*|3.3*|3.4*|3.5*|4.*) log "ruby $version accepted" ;;
    *) log "ruby $version is below the 3.2 floor required by haml"; exit 1 ;;
  esac
}
```

- [ ] **Step 2: swap を作る関数を足す**

同じファイルに追加する:

```bash
configure_swap() {
  if swapon --show | grep -q '/swapfile'; then
    log "swap already active"
    return 0
  fi

  log "creating 2 GiB swap file"
  dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || printf '/swapfile none swap sw 0 0\n' >> /etc/fstab
}
```

swap を置くのは、解析コンテナがメモリを使う場面で OOM Killer に Puma を落とされるのを避けるためである。

- [ ] **Step 3: アプリ設定と example の配置を直す**

`configure_app` を以下に置き換える:

```bash
configure_app() {
  log "configuring app"
  cat > "$APP_DIR/config.yaml" <<EOF
workdir: "/tmp/wpgsa"
network_file_path: "$APP_DIR/data/merged_mouse_150904_trim.network"
max_concurrent_jobs: ${MAX_CONCURRENT_JOBS:-2}
EOF

  if [ ! -f "$APP_DIR/data/merged_mouse_150904_trim.network" ]; then
    log "reference network file is missing from the checkout"
    exit 1
  fi

  if [ ! -f "$APP_DIR/public/data/example/data.hclust.js" ]; then
    log "example dataset is missing from the checkout"
    exit 1
  fi

  mkdir -p /tmp/wpgsa "$APP_DIR/public/data" "$APP_DIR/tmp/sockets" "$APP_DIR/tmp/pids" "$APP_DIR/tmp/slots"
  chmod 0777 /tmp/wpgsa
  chown -R "$APP_USER":"$APP_GROUP" /tmp/wpgsa "$APP_DIR/public/data" "$APP_DIR/tmp"
}
```

- [ ] **Step 4: bundle install を本番向けにする**

`bundle_install` を以下に置き換える:

```bash
bundle_install() {
  log "installing Ruby gems"
  su - "$APP_USER" -c "cd '$APP_DIR' && \
    bundle config set --local path vendor/bundle && \
    bundle config set --local without 'test' && \
    bundle install"
}
```

- [ ] **Step 5: systemd ユニットを Puma にする**

`configure_systemd` の `wpgsa.service` 生成部を以下に置き換える:

```bash
  cat > /etc/systemd/system/wpgsa.service <<EOF
[Unit]
Description=wPGSA Sinatra application
After=network.target docker.service
Requires=docker.service

[Service]
Type=simple
User=$APP_USER
Group=$APP_GROUP
WorkingDirectory=$APP_DIR
Environment=RACK_ENV=production
ExecStart=/usr/bin/env bundle exec puma -C $APP_DIR/config/puma.rb
ExecReload=/bin/kill -USR2 \$MAINPID
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
```

- [ ] **Step 6: 掃除の timer を足す**

同じファイルに追加する:

```bash
configure_cleanup_timer() {
  log "installing cleanup timer"
  cat > /etc/systemd/system/wpgsa-cleanup.service <<EOF
[Unit]
Description=Remove wPGSA job output past its retention window

[Service]
Type=oneshot
User=$APP_USER
Group=$APP_GROUP
WorkingDirectory=$APP_DIR
Environment=WPGSA_WORKDIR=/tmp/wpgsa
Environment=WPGSA_RETENTION_DAYS=${RETENTION_DAYS:-30}
ExecStart=$APP_DIR/script/cleanup-jobs
EOF

  cat > /etc/systemd/system/wpgsa-cleanup.timer <<EOF
[Unit]
Description=Daily wPGSA job cleanup

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now wpgsa-cleanup.timer
}
```

- [ ] **Step 7: nginx を unix socket 経由にし HSTS を足す**

`configure_nginx` の設定生成部を以下に置き換える:

```bash
  cat > /etc/nginx/conf.d/wpgsa.conf <<EOF
upstream wpgsa_app {
    server unix:$APP_DIR/tmp/sockets/puma.sock fail_timeout=0;
}

server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN_NAME _;

    root $APP_DIR/public;
    client_max_body_size 100m;

    add_header Strict-Transport-Security "max-age=${HSTS_MAX_AGE:-300}" always;
    add_header X-Content-Type-Options "nosniff" always;

    location / {
        try_files \$uri @app;
    }

    location @app {
        proxy_pass http://wpgsa_app;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$http_x_forwarded_proto;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;
        proxy_redirect off;
    }
}
EOF
```

`X-Forwarded-Proto` に `\$scheme` ではなく `\$http_x_forwarded_proto` を渡すのは、
TLS を終端しているのが ALB だからである。`\$scheme` は nginx から見た値なので常に `http` になり、
混在コンテンツの原因がそのまま残る。

nginx が `$APP_DIR/public` を読めるよう、ホームディレクトリの実行権を通す:

```bash
  chmod o+x "$APP_DIR"
  chmod -R o+rX "$APP_DIR/public"
```

- [ ] **Step 8: CloudWatch エージェントを入れる**

ディスク使用率は EC2 の標準メトリクスに含まれないため、エージェントが要る。
インスタンスプロファイルは Task 11 で付与する。

```bash
configure_cloudwatch_agent() {
  log "installing CloudWatch agent"
  if ! retry dnf install -y amazon-cloudwatch-agent; then
    log "CloudWatch agent package unavailable; skipping"
    return 0
  fi

  cat > /opt/aws/amazon-cloudwatch-agent/etc/wpgsa-metrics.json <<'EOF'
{
  "agent": { "metrics_collection_interval": 300 },
  "metrics": {
    "append_dimensions": { "InstanceId": "${aws:InstanceId}" },
    "metrics_collected": {
      "disk": {
        "resources": ["/"],
        "measurement": ["disk_used_percent"],
        "metrics_collection_interval": 300
      },
      "mem": {
        "measurement": ["mem_used_percent"],
        "metrics_collection_interval": 300
      }
    }
  }
}
EOF

  /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
    -a fetch-config -m ec2 -s \
    -c file:/opt/aws/amazon-cloudwatch-agent/etc/wpgsa-metrics.json
}
```

ヒアドキュメントの区切りを `'EOF'` と引用しているのは、`${aws:InstanceId}` を
シェルに展開させずそのまま書き出すためである。

- [ ] **Step 9: main に新しい関数を差し込む**

`main` を以下に置き換える:

```bash
main() {
  install_packages
  configure_swap
  create_app_user
  install_bundler
  checkout_app
  configure_app
  bundle_install
  configure_systemd
  configure_cleanup_timer
  configure_nginx
  configure_cloudwatch_agent
  pull_algorithm_image
  show_status
  verify
  log "bootstrap finished"
}
```

TLS は ALB が終端するため、`enable_tls_if_requested` の呼び出しを main から外す。

- [ ] **Step 10: 検証関数を足す**

```bash
verify() {
  log "verifying local endpoints"
  local failed=0

  systemctl is-active --quiet wpgsa || { log "wpgsa.service is not active"; failed=1; }
  systemctl is-active --quiet nginx  || { log "nginx is not active"; failed=1; }
  systemctl is-active --quiet docker || { log "docker is not active"; failed=1; }

  local code
  for path in / /download "/result?uuid=example"; do
    code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1${path}" || echo 000)"
    log "GET ${path} -> ${code}"
    [ "$code" = "200" ] || failed=1
  done

  code="$(curl -s -o /dev/null -w '%{http_code}' 'http://127.0.0.1/wpgsa/result?uuid=example&type=t-score&format=filepath' || echo 000)"
  log "GET /wpgsa/result (example t-score) -> ${code}"
  [ "$code" = "200" ] || failed=1

  if [ "$failed" -ne 0 ]; then
    log "verification FAILED"
    exit 1
  fi
  log "verification passed"
}
```

- [ ] **Step 11: 構文検査する**

```bash
bash -n script/bootstrap-wpgsa-instance.sh && echo "syntax OK"
```

- [ ] **Step 12: commit**

```bash
git add script/bootstrap-wpgsa-instance.sh
git commit -m "Rebuild the bootstrap around Puma and nginx

Replaces rackup with Puma behind an nginx unix socket, adds a swap file
so the analysis container cannot get Puma killed on a 2 GiB host, adds
the daily cleanup timer, and installs gems without the test group.

Forwards X-Forwarded-Proto from the incoming header rather than \$scheme.
The ALB terminates TLS, so \$scheme is always http at nginx and passing
it on reintroduces the mixed content that broke the site over HTTPS.

Installs the CloudWatch agent for disk and memory metrics, which the
standard EC2 metric set does not carry.

Bootstrap now fails loudly when the Ruby package is older than 3.2 or
when the reference network or example dataset is missing from the
checkout, and verifies the local endpoints before reporting success."
```

---

### Task 10: launch スクリプトの修正

**Files:**
- Modify: `script/launch-wpgsa-ec2.sh`

- [ ] **Step 1: SSH の既定値と暗号化、IMDSv2 を直す**

以下の 3 点を変更する。

`SSH_CIDR` の既定値を空にし、未指定なら失敗させる:

```bash
SSH_CIDR="${SSH_CIDR:-}"
```

`main` の `require_env KEY_NAME` の下に足す:

```bash
  require_env SSH_CIDR
  [ "$SSH_CIDR" != "0.0.0.0/0" ] || die "refusing to open SSH to the whole internet; set SSH_CIDR"
```

`launch_instance` のブロックデバイスとメタデータ指定を変える:

```bash
    --block-device-mappings "[{\"DeviceName\":\"/dev/xvda\",\"Ebs\":{\"VolumeSize\":${ROOT_VOLUME_SIZE},\"VolumeType\":\"gp3\",\"Encrypted\":true,\"DeleteOnTermination\":true}}]"
    --metadata-options "HttpTokens=required,HttpEndpoint=enabled"
```

- [ ] **Step 2: ブランチの既定値を変える**

切り替え検証は本ブランチから行うため:

```bash
APP_BRANCH="${APP_BRANCH:-stage1-rebuild}"
```

- [ ] **Step 3: 構文検査する**

```bash
bash -n script/launch-wpgsa-ec2.sh && echo "syntax OK"
```

- [ ] **Step 4: commit**

```bash
git add script/launch-wpgsa-ec2.sh
git commit -m "Harden instance launch defaults

SSH_CIDR defaulted to 0.0.0.0/0, so a launch with no arguments opened
SSH to the internet. It is now required and refuses that value.

Root volumes are encrypted and IMDSv2 is mandatory, which removes two of
the Security Hub findings the current production instance carries."
```

---

### Task 11: 新インスタンスの構築と検証

**Files:** なし（AWS 操作）

- [ ] **Step 1: ブランチを push する**

bootstrap はリポジトリから clone するため、先にリモートへ出す:

```bash
git push -u origin stage1-rebuild
```

- [ ] **Step 2: CloudWatch エージェント用のインスタンスプロファイルを作る**

エージェントがメトリクスを送るための権限を用意する。起動時に渡すため、先に作る。

```bash
cat > /tmp/ec2-trust.json <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "ec2.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
JSON

aws iam create-role --profile riken \
  --role-name wpgsa-instance \
  --assume-role-policy-document file:///tmp/ec2-trust.json

aws iam attach-role-policy --profile riken \
  --role-name wpgsa-instance \
  --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy

aws iam create-instance-profile --profile riken \
  --instance-profile-name wpgsa-instance

aws iam add-role-to-instance-profile --profile riken \
  --instance-profile-name wpgsa-instance \
  --role-name wpgsa-instance
```

すでに存在する場合は `EntityAlreadyExists` が返る。その場合は次へ進む。

- [ ] **Step 3: インスタンスを起動する**

`SSH_CIDR` には作業元のグローバル IP を入れる:

```bash
export AWS_PROFILE=riken
export AWS_REGION=ap-northeast-1
export KEY_NAME=wpgsa-202402
export SSH_CIDR="$(curl -s https://checkip.amazonaws.com | tr -d '\n')/32"
export APP_BRANCH=stage1-rebuild
export INSTANCE_TYPE=t3.small
export SECURITY_GROUP_ID=sg-0afcd77f843b6a2b0
export SUBNET_ID=subnet-098154d5afe513288
export VPC_ID=vpc-012b8ad40d152e0e8
export HOSTNAME_TAG=wpgsa-org-stage1
export INSTANCE_PROFILE_NAME=wpgsa-instance

bash script/launch-wpgsa-ec2.sh
```

出力されたインスタンス ID を控える。以下 `$NEW_ID` と書く。

- [ ] **Step 4: bootstrap の完了を待って結果を読む**

```bash
ssh -i ~/.ssh/wpgsa-202402.pem ec2-user@<new-public-ip> \
  'sudo tail -n 60 /var/log/wpgsa-bootstrap.log'
```

期待: 末尾に `verification passed` と `bootstrap finished` が出る。
`verification FAILED` なら、その手前のログで落ちた項目を特定して直す。

- [ ] **Step 5: 直接アクセスで受け入れ基準 1 から 3 を確認する**

まだ ALB には登録しない。

```bash
NEW_IP=<new-public-ip>
for p in / /download "/result?uuid=example" "/result/heatmap?uuid=example"; do
  printf '%-36s %s\n' "$p" "$(curl -s -o /dev/null -w '%{http_code}' "http://$NEW_IP$p")"
done
echo "--- 資産の参照先が X-Forwarded-Proto に従うか ---"
curl -s -H "X-Forwarded-Proto: https" -H "Host: wpgsa.org" "http://$NEW_IP/" \
  | grep -oE "(href|src)='[^']*(css|js)[^']*'" | sort -u
```

期待: すべて 200。資産の URL がすべて `https://wpgsa.org/...` になっていること。
`http://` が 1 件でも出たら、この時点で止めて nginx の `X-Forwarded-Proto` 設定を見直す。

- [ ] **Step 6: 非同期の挙動を確認する（受け入れ基準 4）**

`data/` の入力例を使って POST し、202 が即座に返ることを見る:

```bash
curl -s -o /dev/null -w 'status=%{http_code} time=%{time_total}\n' \
  -F "file=@public/data/example/sample.logfc_TF_wPGSA_z_score.txt" \
  "http://$NEW_IP/wpgsa/result"
```

期待: `status=202` で `time` が数秒以内。

90 秒を超えるジョブの確認は、サーバ上で一時的にランナーの先頭へ待ちを挟んで行う:

```bash
ssh -i ~/.ssh/wpgsa-202402.pem ec2-user@$NEW_IP \
  "sudo sed -i '/^job = WPGSA::Job.load/i sleep 95' /opt/wpgsa.org/script/run-job"
```

ブラウザで `http://$NEW_IP/` を開き、ファイルを選んで送信し、
95 秒待ったあとに結果ページへ遷移することを確認する。
確認できたら元に戻す:

```bash
ssh -i ~/.ssh/wpgsa-202402.pem ec2-user@$NEW_IP \
  "sudo sed -i '/^sleep 95$/d' /opt/wpgsa.org/script/run-job"
```

この変更は commit しない。

- [ ] **Step 7: 一時的な SSH 許可を確認する**

`wpgsa-SG-EC2` を共有しているため、Step 2 で新しい規則は追加されていないはずである。
確認する:

```bash
aws ec2 describe-security-groups --profile riken --region ap-northeast-1 \
  --group-ids sg-0afcd77f843b6a2b0 \
  --query 'SecurityGroups[0].IpPermissions[?FromPort==`22`].IpRanges[].CidrIp' --output text
```

期待: 既存の 4 つの CIDR のみ。作業元 IP が増えていたら、検証後に削除する。

---

## Phase 3: 監視と切り替え

### Task 12: 監視とバックアップの構築

**Files:** なし（AWS 操作）

- [ ] **Step 1: SNS トピックを作り購読する**

```bash
TOPIC_ARN=$(aws sns create-topic --profile riken --region ap-northeast-1 \
  --name wpgsa-alerts --query TopicArn --output text)
echo "$TOPIC_ARN"

aws sns subscribe --profile riken --region ap-northeast-1 \
  --topic-arn "$TOPIC_ARN" --protocol email --notification-endpoint inutano@gmail.com
```

届いた確認メールのリンクを開いて購読を確定する。

- [ ] **Step 2: ALB のアラームを作る**

```bash
LB=app/wpgsa-ELB/094927c662a6ec95
TG=targetgroup/wpgsa-TG/84fe8f99ed28c72a

aws cloudwatch put-metric-alarm --profile riken --region ap-northeast-1 \
  --alarm-name wpgsa-unhealthy-hosts \
  --namespace AWS/ApplicationELB --metric-name UnHealthyHostCount \
  --dimensions Name=LoadBalancer,Value=$LB Name=TargetGroup,Value=$TG \
  --statistic Maximum --period 60 --evaluation-periods 2 \
  --threshold 1 --comparison-operator GreaterThanOrEqualToThreshold \
  --treat-missing-data notBreaching --alarm-actions "$TOPIC_ARN"

aws cloudwatch put-metric-alarm --profile riken --region ap-northeast-1 \
  --alarm-name wpgsa-target-5xx \
  --namespace AWS/ApplicationELB --metric-name HTTPCode_Target_5XX_Count \
  --dimensions Name=LoadBalancer,Value=$LB Name=TargetGroup,Value=$TG \
  --statistic Sum --period 300 --evaluation-periods 1 \
  --threshold 5 --comparison-operator GreaterThanOrEqualToThreshold \
  --treat-missing-data notBreaching --alarm-actions "$TOPIC_ARN"

aws cloudwatch put-metric-alarm --profile riken --region ap-northeast-1 \
  --alarm-name wpgsa-slow-responses \
  --namespace AWS/ApplicationELB --metric-name TargetResponseTime \
  --dimensions Name=LoadBalancer,Value=$LB Name=TargetGroup,Value=$TG \
  --extended-statistic p95 --period 300 --evaluation-periods 3 \
  --threshold 5 --comparison-operator GreaterThanThreshold \
  --treat-missing-data notBreaching --alarm-actions "$TOPIC_ARN"
```

- [ ] **Step 3: ディスクのアラームを作る**

Task 9 で入れた CloudWatch エージェントが `CWAgent` 名前空間へ送っている。
まず実際に届いているディメンションを確認する:

```bash
aws cloudwatch list-metrics --profile riken --region ap-northeast-1 \
  --namespace CWAgent --metric-name disk_used_percent \
  --dimensions Name=InstanceId,Value="$NEW_ID" --output json
```

期待: メトリクスが 1 件以上返る。エージェントの初回送信まで 5 分ほどかかる。
空なら待ってから再実行する。返ってきた `Dimensions` をそのまま次で使う。

```bash
aws cloudwatch put-metric-alarm --profile riken --region ap-northeast-1 \
  --alarm-name wpgsa-disk-usage \
  --namespace CWAgent --metric-name disk_used_percent \
  --dimensions Name=InstanceId,Value="$NEW_ID" Name=path,Value=/ Name=fstype,Value=xfs \
  --statistic Average --period 300 --evaluation-periods 2 \
  --threshold 80 --comparison-operator GreaterThanOrEqualToThreshold \
  --treat-missing-data missing --alarm-actions "$TOPIC_ARN"
```

`path` と `fstype` のディメンションは、直前の `list-metrics` が返した値に合わせる。
AL2023 の既定は `xfs` だが、一致しないとアラームがデータを見つけられない。

作成後、状態が `INSUFFICIENT_DATA` のまま留まらないことを確認する:

```bash
sleep 600
aws cloudwatch describe-alarms --profile riken --region ap-northeast-1 \
  --alarm-names wpgsa-disk-usage --query 'MetricAlarms[0].StateValue' --output text
```

期待: `OK`

- [ ] **Step 4: 通知が届くことを確認する（受け入れ基準 8）**

```bash
aws cloudwatch set-alarm-state --profile riken --region ap-northeast-1 \
  --alarm-name wpgsa-unhealthy-hosts --state-value ALARM \
  --state-reason "manual verification of the notification path"
```

期待: メールが届く。届いたら状態を戻す:

```bash
aws cloudwatch set-alarm-state --profile riken --region ap-northeast-1 \
  --alarm-name wpgsa-unhealthy-hosts --state-value OK --state-reason "verification complete"
```

- [ ] **Step 5: DLM で AMI を日次取得する**

DLM 用のロールを用意してからポリシーを作る:

```bash
aws dlm create-default-role --profile riken --region ap-northeast-1 --resource-type image

cat > /tmp/dlm-policy.json <<'JSON'
{
  "ResourceTypes": ["INSTANCE"],
  "TargetTags": [{"Key": "Project", "Value": "wpgsa.org"}],
  "Schedules": [{
    "Name": "daily-ami",
    "CreateRule": {"Interval": 24, "IntervalUnit": "HOURS", "Times": ["18:00"]},
    "RetainRule": {"Count": 7},
    "CopyTags": true
  }]
}
JSON

ACCOUNT=463278513270
aws dlm create-lifecycle-policy --profile riken --region ap-northeast-1 \
  --description "wpgsa.org daily AMI" \
  --state ENABLED \
  --execution-role-arn "arn:aws:iam::${ACCOUNT}:role/AWSDataLifecycleManagerDefaultRoleForAMIManagement" \
  --policy-details file:///tmp/dlm-policy.json
```

新インスタンスに `Project=wpgsa.org` タグが付いていることを確認する:

```bash
aws ec2 describe-instances --profile riken --region ap-northeast-1 \
  --instance-ids "$NEW_ID" --query 'Reservations[0].Instances[0].Tags' --output table
```

期待: `Project` が `wpgsa.org`。無ければ付ける:

```bash
aws ec2 create-tags --profile riken --region ap-northeast-1 \
  --resources "$NEW_ID" --tags Key=Project,Value=wpgsa.org
```

- [ ] **Step 6: ALB のアクセスログを有効にする**

```bash
ACCOUNT=463278513270
BUCKET="wpgsa-alb-logs-${ACCOUNT}"

aws s3api create-bucket --profile riken --region ap-northeast-1 \
  --bucket "$BUCKET" \
  --create-bucket-configuration LocationConstraint=ap-northeast-1

aws s3api put-lifecycle-configuration --profile riken --bucket "$BUCKET" \
  --lifecycle-configuration '{"Rules":[{"ID":"expire-90d","Status":"Enabled","Filter":{"Prefix":""},"Expiration":{"Days":90}}]}'
```

バケットポリシーで ap-northeast-1 の ELB アカウント `582318560864` に書き込みを許可する:

```bash
cat > /tmp/alb-log-policy.json <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"AWS": "arn:aws:iam::582318560864:root"},
    "Action": "s3:PutObject",
    "Resource": "arn:aws:s3:::${BUCKET}/AWSLogs/${ACCOUNT}/*"
  }]
}
JSON

aws s3api put-bucket-policy --profile riken --bucket "$BUCKET" --policy file:///tmp/alb-log-policy.json

aws elbv2 modify-load-balancer-attributes --profile riken --region ap-northeast-1 \
  --load-balancer-arn arn:aws:elasticloadbalancing:ap-northeast-1:463278513270:loadbalancer/app/wpgsa-ELB/094927c662a6ec95 \
  --attributes Key=access_logs.s3.enabled,Value=true Key=access_logs.s3.bucket,Value="$BUCKET"
```

期待: エラーなく完了する。失敗する場合はポリシーの Principal を確認する。

---

### Task 13: ターゲットの差し替え

**Files:** なし（AWS 操作）

- [ ] **Step 1: 現在の登録状態を記録する**

戻すときに使う:

```bash
TG_ARN=arn:aws:elasticloadbalancing:ap-northeast-1:463278513270:targetgroup/wpgsa-TG/84fe8f99ed28c72a
aws elbv2 describe-target-health --profile riken --region ap-northeast-1 \
  --target-group-arn "$TG_ARN" --output table
```

期待: `i-0650fe6a3ca5f5b4d` が 1 件、`healthy`。

- [ ] **Step 2: 新インスタンスを登録する**

```bash
aws elbv2 register-targets --profile riken --region ap-northeast-1 \
  --target-group-arn "$TG_ARN" --targets Id="$NEW_ID",Port=80

aws elbv2 wait target-in-service --profile riken --region ap-northeast-1 \
  --target-group-arn "$TG_ARN" --targets Id="$NEW_ID",Port=80
echo "new instance is in service"
```

この時点では新旧の 2 台に振り分けられる。両方が同じ結果を返すわけではないため、
この状態を長く保たない。

- [ ] **Step 3: 旧インスタンスを登録解除する**

```bash
aws elbv2 deregister-targets --profile riken --region ap-northeast-1 \
  --target-group-arn "$TG_ARN" --targets Id=i-0650fe6a3ca5f5b4d,Port=80

aws elbv2 wait target-deregistered --profile riken --region ap-northeast-1 \
  --target-group-arn "$TG_ARN" --targets Id=i-0650fe6a3ca5f5b4d,Port=80
```

- [ ] **Step 4: 本番 URL で受け入れ基準 1 と 3 を確認する**

```bash
echo "--- 資産の参照先 ---"
curl -s https://wpgsa.org/ | grep -oE "(href|src)='[^']*(css|js)[^']*'" | sort -u
echo "--- 各ページ ---"
for p in / /download "/result?uuid=example" "/result/heatmap?uuid=example" /nosuchstylesheet.css; do
  printf '%-40s %s\n' "$p" "$(curl -s -o /dev/null -w '%{http_code}' "https://wpgsa.org$p")"
done
```

期待: 資産の URL がすべて `https://`。ページはすべて 200、`/nosuchstylesheet.css` は 404。

ブラウザで `https://wpgsa.org/` を開き、コンソールに混在コンテンツの遮断が出ないこと、
レイアウトが崩れていないこと、Example の結果表とヒートマップが描画されることを目視する。

**この確認が通らない場合は Step 5 へ進まず、ロールバックする:**

```bash
aws elbv2 register-targets --profile riken --region ap-northeast-1 \
  --target-group-arn "$TG_ARN" --targets Id=i-0650fe6a3ca5f5b4d,Port=80
aws elbv2 wait target-in-service --profile riken --region ap-northeast-1 \
  --target-group-arn "$TG_ARN" --targets Id=i-0650fe6a3ca5f5b4d,Port=80
aws elbv2 deregister-targets --profile riken --region ap-northeast-1 \
  --target-group-arn "$TG_ARN" --targets Id="$NEW_ID",Port=80
```

- [ ] **Step 5: ALB の 80 番をリダイレクトに変える**

受け入れ基準 1 を満たしたことを確認してから行う。順序を逆にすると、
壊れた HTTPS へ利用者を強制することになる。

```bash
LISTENER_ARN=$(aws elbv2 describe-listeners --profile riken --region ap-northeast-1 \
  --load-balancer-arn arn:aws:elasticloadbalancing:ap-northeast-1:463278513270:loadbalancer/app/wpgsa-ELB/094927c662a6ec95 \
  --query "Listeners[?Port==\`80\`].ListenerArn" --output text)

aws elbv2 modify-listener --profile riken --region ap-northeast-1 \
  --listener-arn "$LISTENER_ARN" \
  --default-actions '[{"Type":"redirect","RedirectConfig":{"Protocol":"HTTPS","Port":"443","StatusCode":"HTTP_301"}}]'

curl -sSI http://wpgsa.org/ | head -3
```

期待: `HTTP/1.1 301 Moved Permanently` と `location: https://wpgsa.org:443/`。

- [ ] **Step 6: オリジンへの直接アクセスを封鎖する（受け入れ基準 5）**

`wpgsa-SG-EC2` は新旧のインスタンスが共有しているため、1 回の変更で両方に効く。

```bash
aws ec2 revoke-security-group-ingress --profile riken --region ap-northeast-1 \
  --group-id sg-0afcd77f843b6a2b0 \
  --ip-permissions 'IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0}]'

aws ec2 authorize-security-group-ingress --profile riken --region ap-northeast-1 \
  --group-id sg-0afcd77f843b6a2b0 \
  --ip-permissions 'IpProtocol=tcp,FromPort=80,ToPort=80,UserIdGroupPairs=[{GroupId=sg-0e6d9de4c608c5de8,Description=ALB only}]'
```

確認する:

```bash
NEW_IP=$(aws ec2 describe-instances --profile riken --region ap-northeast-1 \
  --instance-ids "$NEW_ID" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

for ip in "$NEW_IP" 18.178.132.253; do
  printf '%-18s %s\n' "$ip" "$(curl -s -m 8 -o /dev/null -w '%{http_code}' "http://$ip/" || echo unreachable)"
done
echo "--- ALB 経由は生きているか ---"
curl -s -o /dev/null -w '%{http_code}\n' https://wpgsa.org/
```

期待: 2 つの IP がどちらも `unreachable`、`https://wpgsa.org/` は 200。

- [ ] **Step 7: 未使用のセキュリティグループを削除する**

どの ENI からも参照されていないことを確かめてから消す:

```bash
for sg in sg-0ab5d7cefcfaef181 sg-039eaf3ed6de0db33; do
  n=$(aws ec2 describe-network-interfaces --profile riken --region ap-northeast-1 \
    --filters Name=group-id,Values=$sg --query 'length(NetworkInterfaces)' --output text)
  echo "$sg: $n interfaces"
  [ "$n" = "0" ] && aws ec2 delete-security-group --profile riken --region ap-northeast-1 --group-id $sg && echo "  deleted"
done
```

- [ ] **Step 8: 一時的な SSH 許可を外す**

Task 11 で作業元 IP を追加していた場合は削除する:

```bash
aws ec2 describe-security-groups --profile riken --region ap-northeast-1 \
  --group-ids sg-0afcd77f843b6a2b0 \
  --query 'SecurityGroups[0].IpPermissions[?FromPort==`22`].IpRanges[].[CidrIp,Description]' --output table
```

既存の 4 つ以外があれば `revoke-security-group-ingress` で削除する。

- [ ] **Step 9: 旧インスタンスを残したまま記録する**

旧インスタンス `i-0650fe6a3ca5f5b4d` は停止せず 4 週間残す。
ターゲットグループから外れているだけなので、いつでも再登録できる。

```bash
aws ec2 create-tags --profile riken --region ap-northeast-1 \
  --resources i-0650fe6a3ca5f5b4d \
  --tags Key=Status,Value="rollback-target-until-2026-09-15"
```

- [ ] **Step 10: PR を作る**

```bash
git push -u origin stage1-rebuild
gh pr create --base master --head stage1-rebuild \
  --title "Stage 1: rebuild on Amazon Linux 2023 with Puma" \
  --body "$(cat <<'BODY'
Replaces the Amazon Linux 1 host running Apache 2.2.34 and Passenger
with an Amazon Linux 2023 instance running nginx and Puma, and brings
the application dependencies back inside support.

- drops sass, redcarpet, rack-protection and rackup; the remaining set
  resolves to rack 3.2.7, rack-session 2.1.2 and sinatra 4.2.1, which
  clears all 26 open Dependabot alerts
- merges the asynchronous upload path so long analyses no longer die at
  the ALB idle timeout
- validates data ids before using them in paths, closing the open
  CodeQL rb/path-injection alert
- runs the analysis container through an argument array instead of a
  shell string
- caps concurrent analyses so they cannot OOM the host
- tracks the example dataset, which every fresh host used to be missing
- adds a minitest suite covering the above

Cutover swapped the ALB target group membership. The old instance is
deregistered but still running as a rollback target until 2026-09-15.

Spec: docs/superpowers/specs/2026-08-18-wpgsa-stage1-rebuild-design.md
Plan: docs/superpowers/plans/2026-08-18-wpgsa-stage1-rebuild.md
BODY
)"
```

---

## 完了確認

設計書の受け入れ基準を、対応するタスクとともに再掲する。

| # | 基準 | 確認するタスク |
|---|---|---|
| 1 | HTTPS で CSS と JS が読め、遮断が出ない | Task 11 Step 5、Task 13 Step 4 |
| 2 | `http://wpgsa.org/` が 443 へリダイレクトする | Task 13 Step 5 |
| 3 | Example の結果表とヒートマップが描画される | Task 11 Step 5、Task 13 Step 4 |
| 4 | アップロードが完走し、90 秒超でも切断されない | Task 11 Step 6 |
| 5 | 新旧インスタンスの IP へ直接到達できない | Task 13 Step 6 |
| 6 | 依存 gem の既知脆弱性が 0 件 | Task 2 Step 8 |
| 7 | launch スクリプトのみで同じ状態を再構築できる | Task 11 Step 3 と Step 4 |
| 8 | アラームの通知が届く | Task 12 Step 4 |
| 9 | `/nonexistent.css` が 404 を返す | Task 8 Step 5、Task 13 Step 4 |
| 10 | 不正な `uuid` が 404 を返す | Task 3 Step 6、Task 8 Step 5 |

## 第1段階の完了後に残るもの

以下は設計書のとおり第2段階に送る。

- 解析エンジンを `chiba-ai-med/wPGSAR` へ入れ替える検討
- 参照ネットワークを ChIP-Atlas 配信のものへ更新する
- インスタンスタイプの見直し
- 切れた外部リンクの手当て（`web.ims.riken.jp` は NXDOMAIN、RIKEN 研究室ページは 404、Giphy の鍵は失効）
- サイト内容の更新
- 2020 年の CloudFormation スタックの整理と旧インスタンスの終了
