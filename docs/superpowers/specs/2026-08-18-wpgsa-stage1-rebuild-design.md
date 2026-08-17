# wpgsa.org 第1段階 再構築 設計書

作成日: 2026-08-18
対象: `wpgsa.org` の実行基盤とアプリケーション層
関連: [MAINTENANCE_PLAN.md](../../../MAINTENANCE_PLAN.md)

## 背景

2026-08-17 の調査で、本番環境に三つの問題が確認された。

第一に、HTTPS で開いたサイトが機能していない。
HTML が CSS と JavaScript を `http://` の絶対 URL で参照しており、ブラウザが能動的混在コンテンツとして遮断する。
アップロードボタンは反応せず、Example の結果表もヒートマップも描画されない。
修正コミット `2552016` は 2026-03-11 に `origin/master` へマージ済みだが、本番へ配備されていない。
本番の Web アプリは 2024 年 2 月頃の状態で止まっている。

第二に、本番ホストが Amazon Linux 1 と Apache 2.2.34 で動いている。
どちらもサポートが終了しており、セキュリティ修正は提供されない。
元 AMI は登録解除済みで再作成できず、最新のバックアップは 2024-02-28 である。
Apache と Passenger の設定はリポジトリに存在せず、そのディスク上にしかない。

第三に、依存 gem に未対応の脆弱性が 26 件ある。
うち 1 件は `rack-session 2.0.0` のセッション偽造（CVE-2026-39324）で深刻度 CRITICAL である。

## 目的

現行の機能を保ったまま、サポート内の OS と依存関係の上で動く本番環境に置き換える。
併せて、放置が 2 年半続いた原因である自動化の不在に手を当てる。

解析アルゴリズムと参照データの刷新は第2段階で扱い、本設計では触れない。

## スコープ

### 含むもの

- Amazon Linux 2023 での新規インスタンス構築
- Puma への移行と依存 gem の刷新
- 非同期ジョブ処理の完成と投入
- パストラバーサルとコマンドインジェクションの修正
- オリジンへの直接アクセスの封鎖、HTTP から HTTPS へのリダイレクト、HSTS
- CloudWatch アラーム、SNS 通知、ALB アクセスログ、DLM による AMI 自動取得
- ALB ターゲットグループの差し替えによる切り替え
- 冪等な bootstrap スクリプトによる再構築手順

### 含まないもの

- 解析エンジンの入れ替え（`inutano/wpgsa:0.5.2` を維持する）
- 参照ネットワークの更新
- 既存の解析結果データの移行
- 切れた外部リンクの修正
- Web の見た目と文言の変更
- 2020 年の CloudFormation スタックの整理

過去に発行した `/result?uuid=...` は失効する。
Example データのみ引き継ぐ。

## 現状の構成

```
Route53 (ALIAS)
  → ALB wpgsa-ELB          443: ACM + WAF / 80: リダイレクトせず転送
      → wpgsa-TG           ターゲット 1 台、アイドルタイムアウト 60 秒
          → i-0650fe6a3ca5f5b4d   Amazon Linux 1 (EIP 18.178.132.253)
                Apache 2.2.34 + Phusion Passenger 6.0.5
                  → Sinatra 4.0.0 (同期アップロード)
                      → docker run inutano/wpgsa:0.5.2
```

セキュリティグループ `wpgsa-SG-EC2` が 80 番を `0.0.0.0/0` に開けているため、
`http://18.178.132.253/` から ALB と WAF を素通りしてアプリへ到達できる。

## 目標の構成

```
Route53 (ALIAS)                 変更なし
  → ALB wpgsa-ELB               443: ACM + WAF / 80: 443 へリダイレクト
      → wpgsa-TG                ターゲットを新インスタンスへ差し替え
          → 新インスタンス      Amazon Linux 2023 (x86_64, t3.small)
                nginx :80       ALB の SG からのみ許可、静的ファイル配信、HSTS
                  → unix socket
                → Puma          systemd: wpgsa.service
                    → Sinatra 4.2.1 (非同期アップロード)
                        → job runner → docker run inutano/wpgsa:0.5.2
                systemd timer   wpgsa-cleanup
```

解析コンテナ `inutano/wpgsa:0.5.2` は amd64 専用であるため、アーキテクチャは x86_64 に固定する。
Graviton による費用削減は第2段階で解析エンジンを入れ替えた後に検討する。

## 設計

### 依存関係の刷新

`sass` は Ruby 4.0.5 で動作することを実測で確認したが、本設計では外す。
理由は、上流が 2019 年に開発を終えていること、および `ffi` というネイティブ拡張を含む 5 gem を引き連れ、
デプロイ先にコンパイラを要求することである。

`views/style.sass` を一度 CSS に変換して `public/css/wpgsa.css` として commit し、
`get "/:source.css"` ルートを削除する。
このルートは未知の名前を与えると 500 を返す不具合の原因でもあり、同時に解消する。
変換後の出力は 1082 バイトで、本番が現在配信している `/style.css` と同じ大きさである。

`redcarpet` はリポジトリ全体で参照がなく、削除する。
`rack-protection` は Sinatra が依存として取り込むため、明示的な宣言と `config.ru` の `require` を削除する。
`rackup` は Puma が `config.ru` を直接読むため不要になる。

結果として直接依存は 4 つになる。

```ruby
source 'https://rubygems.org'
ruby '>= 3.2'

gem 'sinatra'
gem 'puma'
gem 'haml'
gem 'rake'
```

`Gemfile` の下限を 3.2 に置くのは、後述のとおり AL2023 が `ruby3.4` を提供しない場合に
`ruby3.2` へ落とす余地を残すためである。
実際に導入したバージョンは `.ruby-version` に記録する。

解決されるバージョンは検証済みである。

| gem | 現在 | 第1段階 | 備考 |
|---|---|---|---|
| rack | 3.0.9.1 | 3.2.7 | 未対応 20 件の下限 3.1.21 を満たす |
| rack-session | 2.0.0 | 2.1.2 | CRITICAL CVE-2026-39324 を解消 |
| sinatra | 4.0.0 | 4.2.1 | CVE-2024-21510 と CVE-2025-61921 を解消 |
| haml | 6.3.0 | 7.4.1 | Ruby 3.2.0 以上を要求 |
| puma | なし | 8.0.2 | 新規 |
| webrick | 1.8.1 | 依存から消滅 | CVE 2 件が構造的に解消 |
| sass ほか 5 gem | あり | 削除 | ネイティブ拡張の除去 |

この構成で Dependabot の未対応 26 件はすべて解消する。

脆弱性の確認には `bundler-audit` を使う。
実行環境に常駐させる必要はないため `Gemfile` には加えず、
開発機と検証手順の中で `gem install bundler-audit` して用いる。

Ruby は 3.4 を目標とする。
`.ruby-version` に記載し、`Gemfile` にも `ruby` ディレクティブを置く。
bootstrap は AL2023 が提供する `ruby3.x` パッケージのうち最新のものを採り、
3.2 未満しか無い場合は明示的に失敗して停止する。

### アプリケーションの変更

`async-job-processing` ブランチ（コミット `de974af`）を取り込む。
その上で次を追加する。

**同時実行数の制限**
`WPGSA::Job#spawn!` は無制限にプロセスを切り離す。
t3.small のメモリは 2 GiB であり、複数ジョブが重なると不足する。
実行中ジョブ数の上限を設定値として持ち、超過した投入は `queued` のまま待たせる。
拒否はしない。
既存の非同期設計が `queued` を状態として持ち、クライアントがポーリングで待つため、
待ち行列は追加の UI を必要とせずに表現できる。
上限の既定値は 2 とする。

**パストラバーサルの修正**
`WPGSA::Job.load` と `WPGSA::Result#initialize` は、
`params[:uuid]` を検証せずに `File.join(__dir__, "../../public/data", uuid)` へ連結している。
UUID の形式（`/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/`）に一致するか、
リテラル `example` であることを確認してから使う。
一致しない場合は 404 を返す。
CodeQL の未解決警告 `rb/path-injection`（`lib/wpgsa/result.rb:63`）がこれで閉じる。

**コマンドインジェクションの修正**
`WPGSA::Docker#run_wpgsa` と `#run_hclust` は、
ファイル名を補間した文字列をバッククォートで実行している。
`staging_input_data` は空白を `_` に置換するのみで、引用符やドル記号は残る。
`Process.spawn` に配列を渡す形へ変更し、シェルを経由させない。
`run_hclust` は標準出力をファイルへリダイレクトしているため、`:out` オプションで受ける。
アプリプロセスが docker グループに属する構成であり、ここは権限昇格に直結しうる。

**設定の不整合の修正**
`config.yaml` と `lib/tasks/init.rake` は存在しない `merged_mouse_v7_160212.network` を指す。
実在するのは `data/merged_mouse_150904_trim.network` である。
両者を実在するファイル名に合わせる。

**Example データの追跡**
現在 `.gitignore` は `public/data` をディレクトリごと除外しており、
この形では配下に例外を書いても効かない。
除外規則を次のように書き換える。

```
public/data/*
!public/data/example/
```

これで `public/data/example` が Git 管理下に入る。
新しいホストを構築するたびに Example ページが壊れる問題がこれで閉じる。
対象は 5 ファイル、合計 668 KB である。

**掃除**
`public/data` と `/tmp/wpgsa` に古いジョブが残り続け、ディスクが単調に増える。
保持期間を過ぎたジョブを削除する systemd timer を追加する。
既定の保持期間は 30 日とし、`example` は対象外とする。

### ホスト構成

| 項目 | 値 |
|---|---|
| AMI | `/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64` |
| インスタンスタイプ | t3.small |
| ルートボリューム | gp3 30 GiB、暗号化有効 |
| メタデータ | IMDSv2 必須（`HttpTokens=required`） |
| swap | 2 GiB のスワップファイル |
| リバースプロキシ | nginx、unix socket 経由で Puma へ |
| アプリサーバ | Puma、systemd ユニット `wpgsa.service` |
| 解析 | docker、`inutano/wpgsa:0.5.2` |

nginx を残す理由は三つある。
静的ファイルを Ruby プロセスの外で配信できること、
アップロードのリクエストバッファリングが効くこと、
`client_max_body_size` と HSTS ヘッダを Puma の外側で扱えることである。

swap を置く理由は、解析コンテナがメモリを使う場面で OOM Killer に Puma を落とされるのを避けるためである。

### bootstrap の要件

既存の `script/bootstrap-wpgsa-instance.sh` を改良し、次を満たす。

- 何度実行しても同じ状態に収束する（冪等）
- 各ステップが失敗したら、その時点で明確なメッセージを出して停止する
- Ruby のバージョン下限を検証する
- `public/data/example` が配置されていることを検証する
- 完了時に、主要サービスの状態と検証用 URL の応答を出力する

現行スクリプトから修正する点は次のとおりである。

- `SSH_CIDR` の既定値 `0.0.0.0/0` を廃止し、明示的な指定を必須にする
- `rackup` ではなく Puma を起動する systemd ユニットを書く
- `public/data/example` をリポジトリから配置する
- 掃除用の systemd timer を設置する
- swap を作成する
- インスタンスのメタデータオプションに IMDSv2 必須を指定する

`script/launch-wpgsa-ec2.sh` には `run-instances` の引数を配列で組み立てる修正が
`async-job-processing` ブランチに入っている。これを取り込む。

### 切り替え手順

DNS も証明書も触らない。
切り替えの単位は ALB のターゲット登録のみであり、伝播待ちが発生しない。

1. 新インスタンスを構築する。`wpgsa-TG` には登録しない。
2. セキュリティグループに作業者の IP からの一時的な許可を入れ、直接アクセスで検証する。
3. 受け入れ基準の 1 から 4 を満たすことを確認する。
4. 一時的な許可を削除する。
5. 新インスタンスを `wpgsa-TG` に登録し、`healthy` になるまで待つ。
6. 旧インスタンス `i-0650fe6a3ca5f5b4d` を `wpgsa-TG` から登録解除する。
7. 受け入れ基準の全項目を本番 URL で確認する。

### ロールバック

手順 6 までに問題が出た場合は、旧インスタンスを登録したまま新インスタンスを登録解除する。
手順 7 で問題が出た場合は、旧インスタンスを再登録してから新インスタンスを登録解除する。

旧インスタンスは切り替え後も停止せずに 4 週間残す。
その間はいつでも登録し直せる。
4 週間を過ぎたら停止し、CloudFormation スタックの整理と合わせて終了を判断する。

### インフラ堅牢化

| 対象 | 変更 |
|---|---|
| `wpgsa-SG-EC2` | 80 番の許可元を `0.0.0.0/0` から ALB の SG `sg-0e6d9de4c608c5de8` の参照へ |
| ALB リスナ 80 | 転送からリダイレクト（HTTP 301、443 へ）へ |
| nginx | `Strict-Transport-Security` を付与。`max-age` は 300 秒から開始し、確認後に延長 |
| 未使用 SG | `sg-0ab5d7cefcfaef181`、`sg-039eaf3ed6de0db33` を削除 |

ALB リスナ 80 のリダイレクト化は、受け入れ基準 1 を満たしたことを確認してから実施する。
順序を逆にすると、混在コンテンツで壊れた HTTPS へ利用者を強制することになる。

### 監視とバックアップ

SNS トピックを 1 つ作り、メールアドレスを購読させる。
以下の CloudWatch アラームがそこへ通知する。

| アラーム | メトリクス | しきい値 |
|---|---|---|
| ターゲット異常 | `UnHealthyHostCount` | 1 以上が 2 回連続（5 分） |
| サーバエラー | `HTTPCode_Target_5XX_Count` | 5 分間で 5 以上 |
| 応答遅延 | `TargetResponseTime` | p95 が 5 秒を超える状態が 3 回連続 |
| ディスク | CloudWatch エージェントの `disk_used_percent` | 80% 以上 |

ALB のアクセスログを S3 バケットへ有効化し、ライフサイクルで 90 日後に失効させる。

DLM のライフサイクルポリシーで、本番インスタンスの AMI を日次で取得し 7 世代保持する。
CloudWatch エージェントを動かすため、インスタンスプロファイルに
`CloudWatchAgentServerPolicy` を付与する。

## 受け入れ基準

1. `https://wpgsa.org/` で CSS と JavaScript が読み込まれ、ブラウザのコンソールに混在コンテンツの遮断が出ない
2. `http://wpgsa.org/` が 443 へリダイレクトする
3. `/result?uuid=example` の結果表と `/result/heatmap?uuid=example` のヒートマップが描画される
4. 実データのアップロードから結果表示まで完走する。併せて次の 2 点を確認する。
   - `POST /wpgsa/result` がジョブの長さによらず数秒以内に 202 を返す
   - 90 秒以上を要するジョブが結果ページまで到達する
     （検証時に限り、ランナーの先頭へ一時的に `sleep` を挟んで再現する。この変更は commit しない）
5. 新インスタンスのパブリック IP に対する `http://<new-ip>/` が接続できない。
   旧インスタンスの `http://18.178.132.253/` も同様に接続できない
   （両者は `wpgsa-SG-EC2` を共有するため、1 回の変更で両方に効く）
6. `bundle exec bundler-audit check --update` が脆弱性を報告しない
7. `script/launch-wpgsa-ec2.sh` の実行のみで、同じ状態のインスタンスが構築できる
8. アラームを意図的に発火させ、通知が届くことを確認できる
9. `/nonexistent.css` が 500 ではなく 404 を返す
10. UUID の形式に一致しない `uuid` を与えたとき、`/wpgsa/job` と `/wpgsa/result` が 404 を返す

## リスクと未確定事項

**旧ホストの構成が回収できない可能性**
本設計は旧ホストへの SSH を前提としない。
アプリのコード、参照ネットワーク（Git 管理下、67 MB）、Example データ（作業ツリーに現存）が揃っており、
新環境をグリーンフィールドとして構築できる。
旧ホストへのログインは、切り戻しの判断材料を得るための調査という位置づけに留める。
ただし、旧ホストにのみ存在する設定や運用上の細工がある場合、それを取りこぼす可能性は残る。

**解析コンテナが 2016 年製である**
`inutano/wpgsa:0.5.2` は Docker Hub に現存し取得できることを確認した（マニフェスト v2）。
中身は Python 2 と 2016 年の conda 環境である。
第1段階ではこれを維持するため、Python 2 に起因する問題は解消しない。
Docker Hub の保持方針が変わった場合、取得できなくなる可能性がある。
軽減策として、切り替え前にイメージを ECR へ複製することを検討する。

**Ruby 3.4 パッケージの入手性**
AL2023 が `ruby3.4` を提供するかは実機で確認していない。
提供されない場合は `ruby3.2` を用いる。
`haml` 7.4.1 の下限が 3.2.0 であるため、3.2 でも本設計の依存構成は成立する。

**t3.small のメモリ**
現行の参照ネットワークは 67 MB であり、2 GiB で足りている。
第2段階で ChIP-Atlas 由来のネットワーク（1.0 から 1.2 GB）へ移る際は、
インスタンスタイプの見直しが前提になる。

**CloudFormation スタックの扱い**
2020 年のスタック `EC2Stack`、`VPCStack`、`Route53Stack` が、
旧インスタンス、EIP、VPC、ホストゾーンを今も所有している。
スタックの定義は現在の構成と一致しない。
第1段階では旧インスタンスを終了しないため、この判断を先送りできる。
旧インスタンスの終了はスタックの整理とセットで別途扱う。

## 第2段階への引き継ぎ

第2段階で扱う項目を記録しておく。

- 解析エンジンを `chiba-ai-med/wPGSAR`（R パッケージ、2025 年、Zenodo DOI と CI あり）へ入れ替える検討
- 参照ネットワークを ChIP-Atlas 配信のものへ更新する
  （`https://chip-atlas.dbcls.jp/data/hg38/wpgsa/wpgsa_GRN.hg38.5.tsv` 1.22 GB、
  `.../mm10/wpgsa/wpgsa_GRN.mm10.5.tsv` 1.01 GB、いずれも 2026-08-17 時点で取得可能）
  - 現行の 6 列形式と非互換であり、集計の粒度が転写因子単位から実験単位へ変わる
  - 出力の解釈が変わるため、既知データでの検証が必要になる
- インスタンスタイプの見直し（メモリと、amd64 制約が外れた場合の Graviton 移行）
- 切れた外部リンクの手当て
  - `web.ims.riken.jp` は NXDOMAIN であり、ピークデータの配布先を決め直す必要がある
  - RIKEN 研究室ページは 404、Giphy の API 鍵は失効している
- サイト内容の更新（Change Log は 2016 年 10 月で止まっている）
