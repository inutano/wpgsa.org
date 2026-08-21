# 引き継ぎ

最終更新: 2026-08-21 / 対象: `v1.0.0`（第1段階完了時点）

第1段階（実行基盤の再構築）が完了し、本番へ反映済みである。
第2段階（解析実装と参照データの刷新）はまだ着手していない。

## 現況

| 項目 | 値 |
|---|---|
| `master` | `0d450f1`（タグ `v1.0.0`） |
| 稼働インスタンス | `i-04641aa4b2fd3bb1a` / `57.180.251.171` / t3.small |
| テスト | 100件 |
| Dependabot / CodeQL の未対応 | 0件 / 0件 |
| CloudWatch アラーム | 4件（すべて OK、SNS `wpgsa-alerts` へ通知） |
| CloudFormation スタック | `Route53Stack`、`VPCStack`（どちらも IN_SYNC） |

AWS は account `463278513270`、region `ap-northeast-1`、`--profile riken` で操作する。
SSH 鍵は `~/.ssh/wpgsa-202402.pem`。

## 構成

```
Route53 (ALIAS)
  → ALB wpgsa-ELB        443: ACM + WAF / 80: 443 へリダイレクト
      → wpgsa-TG
          → i-04641aa4b2fd3bb1a   Amazon Linux 2023
                nginx :80         ALB の SG からのみ許可
                  → unix socket (mode 660, nginx は wpgsa グループ)
                → Puma            systemd: wpgsa.service
                    → Sinatra 4.2.1
                        → 切り離されたランナー → docker run inutano/wpgsa:0.5.2
                systemd timer     wpgsa-cleanup（日次、保持30日）
```

## 触ってはいけないもの

**`VPCStack` と `Route53Stack` を削除しないこと。**
名前が `MathReasoning*` で無関係な別プロジェクトの名残に見えるが、中身は現役である。
前者は稼働インスタンスと ALB が存在する VPC・サブネット・IGW・ルートテーブルを、
後者はホストゾーンと `wpgsa.org` の A レコード（ALB への ALIAS）を所有する。

ホストゾーンを失うと NS が変わり、レジストラ側の委任更新が必要になる。
`wpgsa.org` は Route 53 Domains に登録されておらず**レジストラが不明**なため、
これは「作り直せばよい」類の損失ではない。

**systemd ユニットの以下2行を消さないこと。**

- `Environment=RACK_ENV=production` — 無いと Sinatra が development になり、
  ホスト認可が localhost 限定になって ALB 経由の全リクエストが 403 になる
- `KillMode=process` — 無いと `systemctl restart wpgsa` が実行中の解析を道連れに殺す

**nginx の `proxy_set_header X-Forwarded-Proto $http_x_forwarded_proto;` を
`$scheme` に変えないこと。** ALB が TLS を終端するため `$scheme` は常に `http` であり、
2024年から本番を壊していた混在コンテンツの不具合がそのまま再発する。

**参照ネットワークを5列形式以外に差し替えないこと。**
`inutano/wpgsa:0.5.2` の wPGSA.py 1.1.0 は列2を標的遺伝子、列3を `positive No.`、
列4を `experiment No.` として読む（0起点）。列数の違うファイルを渡しても
コンテナは正常終了し、結果表も全件そろって出る。重みだけが別の列から計算される。
第1段階で6列の `merged_mouse_150904_trim.network` を指してしまい、
重みが `Entrez遺伝子ID / positive No.` になっていた。
`test/test_network_file.rb` がこの形式を検査している。

## 実機作業の勘所

**AL2023 の Ruby はバージョン付きバイナリしか置かない。**
`ruby3.4` は `/usr/bin/ruby` を提供するが `gem` / `bundle` / `bundler` は提供せず、
alternatives が管理するのは `ruby` だけである。`/usr/bin/${RUBY_PKG}-gem` を使う。
同梱の Bundler は 2.6.9 で、本リポジトリの Bundler 4 系ロックファイルを拒否する。

**デプロイ手順が Git 管理下のファイルを書いてはいけない。**
この原則を破った欠陥が2件あった（`Gemfile.lock` と `config.yaml`）。
どちらもホスト上の `git checkout` と `git pull --ff-only` を壊した。
前者は `bundle config set --local frozen true`、後者は相対パスをアプリのルートから
解決する形で解消済みである。同じことを繰り返さないこと。

**`/root/bootstrap-wpgsa-instance.sh` は起動時に user-data へ埋め込まれたコピーである。**
その後のスクリプト変更を含まないので、稼働ホストに反映するときは
`/opt/wpgsa.org/script/` のチェックアウト版を使う。

**WAF がリクエストボディを 8 KB で遮断する。**
`AWSManagedRulesCommonRuleSet` の `SizeRestrictions_BODY` によるもので、
2024年6月の ALB 作成以来ずっとアップロードを塞いでいた。
現在はこのルールのみ Count に上書きしてある。他のルールは有効なまま。

**CloudFormation のドリフト検出は `AWS::Route53::RecordSet` に対応していない。**
テンプレートと実レコードが食い違っていても `IN_SYNC` と報告する。
実際にこの状態が2024年から放置されており、`update-stack` を実行すれば
本番 DNS が死んだインスタンスに向き直るところだった。現在は解消済み。

**このシェルは zsh で、引用符なし変数を単語分割しない。**
`P="--profile riken"` としてから `aws $P ...` とすると1つの不正な引数として渡る。
`export AWS_PROFILE=riken` を使う。

## ロールバック

コードを戻す場合、bootstrap の `APP_BRANCH` にタグ名をそのまま指定できる
（使い捨てクローンで実測済み）。新インスタンスを立てて `wpgsa-TG` のターゲットを
入れ替え、問題があれば逆順で戻す。DNS と証明書には触れない。

ホストごと戻す場合は以下の AMI から起動する。

- `ami-0f92e0a2e9021efa5` — `v1.0.0` 時点の本番ホスト
- `ami-09b044c72771e6f01` — 切り替え前の Amazon Linux 1 環境

旧 Amazon Linux 1 環境そのものへは戻せない。インスタンス、Elastic IP、`EC2Stack` は
削除済みで、AMI からの起動は別インスタンスの新規構築であって切り替えではない。

## 監視

DLM ポリシー `policy-07fa87a7fae6e659a` が日次18時に AMI を取得し7世代保持する。

**未確認事項:** このポリシーは 2026-08-21 に作り直したばかりで、
まだ一度もスケジュール実行の成功を目撃していない。
最初の実行後に `aws ec2 describe-images --owners self --profile riken` で
AMI が増えていることを確認すること。
前身のポリシーは `PolicyType` の指定漏れで作成直後は ENABLED でありながら
初回実行で ERROR になり、一度も AMI を作らなかった。

## 第2段階の材料

解析コンテナ `inutano/wpgsa:0.5.2` は2016年製の Python 2 環境で、
参照ネットワークはマウス限定の 57 MB ファイルである。これらの刷新が第2段階になる。

2026-08-17 に取得を確認した材料:

- **`chiba-ai-med/wPGSAR`** — Koki Tsuyuzaki と Eiryo Kawakami による R パッケージ。
  Kawakami は原論文の共著者。Zenodo DOI、Dockerfile、CI を備える
- **ChIP-Atlas が wPGSA 用ネットワークを配信中**（いずれも HTTP 200 を確認）
  - `https://chip-atlas.dbcls.jp/data/hg38/wpgsa/wpgsa_GRN.hg38.5.tsv`（1.22 GB）
  - `.../mm10/wpgsa/wpgsa_GRN.mm10.5.tsv`（1.01 GB。wPGSAR のコードは mm10 を
    未提供として拒否するが、ファイル自体は存在する）

単純な差し替えにはならない。現行は5列でウェイトを `positive No.` と `experiment No.` から
算出するのに対し、ChIP-Atlas 版は `SRX_id` と遺伝子名の2列にメタデータの別ファイルが付き、
wPGSAR はウェイトを一律1にしている。集計の粒度が転写因子単位から実験単位へ変わるため、
出力の解釈が変わり、既知データでの検証が要る。

2026-08-21 に両実装を同一入力（GSE63786、21,200遺伝子 × 14サンプル）で実測した結果:

- **性能** レガシー 166秒 / ピーク 606 MiB に対し、wPGSAR は 0.48秒 / 約 0.4 GB。
  約350倍の差で、原因は三重ループと疎行列積という計算の組み方の違いである
- **結果の差** 同一ネットワーク・同一入力なら符号は100%一致、pearson 0.956。
  ただし \|t\| 上位20の一致率は中央値 0.33 しかない。差は標準誤差の分母ひとつに由来し、
  レガシーはネットワーク上の標的遺伝子数、wPGSAR は発現データと共有する遺伝子上の
  ウェイト合計 Σw を使う。比 `sqrt(size/Σw)` は 0.71〜3.77 の範囲でTFごとに変わる
- **ChIP-Atlas 規模** mm10（57,585,550行、19,509 SRX、869 TF）で wPGSAR を動かすと、
  `wPGSA()` 本体は7秒だが、ネットワークオブジェクトの構築だけでピーク RSS 7〜8 GB を要する。
  t3.small（1.9 GB + swap 2 GB）では動かない
- **出力の互換性** wPGSAR はサンプルごとの p 値・q 値を返さない（`tstat`、`tstat_se` と
  グループ検定のみ）。階層クラスタリング相当も無い。サイトの3ファイル構成と
  フロントの固定3列を満たすには出力アダプタが要る
- **wPGSAR 側の要確認点** `retrieveNetworkData(assembly="hg19")` が落とすのは hg38 のファイル。
  mm10 は `stop()` で拒否されるがファイルは実在する。
  疎行列対応を謳うが `apply(expression_data, 2, var)` が密化する

## 第1段階で積み残した項目

- **切れた外部リンク**
  - `web.ims.riken.jp` が NXDOMAIN。`/download` の主機能である
    ピークデータ配布ボタンが死んでいる。配布先を決め直す必要がある
  - RIKEN の研究室ページが 404
  - 404 ページの Giphy API 鍵が失効（`403 BANNED`）
- **サイト内容**が2016年10月で止まっている（Change Log、Future Work）
- **`bootstrap.min.css` が参照する eot フォント**が 404。
  IE8 以前専用で、そもそも本サイトが動かないブラウザのため意図的に未対応
- **`fonts` 以外の Bootstrap 3 / jQuery 1.11.2** が2016年のまま

## 記録の在処

- 設計書: `docs/superpowers/specs/2026-08-18-wpgsa-stage1-rebuild-design.md`
- 実装計画: `docs/superpowers/plans/2026-08-18-wpgsa-stage1-rebuild.md`
- リリースノート: https://github.com/inutano/wpgsa.org/releases/tag/v1.0.0

`MAINTENANCE_PLAN.md` は第1段階より前に書かれたもので、Phase 0 と Phase 1 は完了済み。
Phase 3（参照ネットワークの刷新）が上記の第2段階にあたる。
