# wPGSAR への上流貢献 設計書

作成日: 2026-08-21 / 対象: `chiba-ai-med/wPGSAR` 0.99.2

## 目的

wpgsa.org の解析エンジンを、2016年製の Python 2 コンテナ `inutano/wpgsa:0.5.2` から
R パッケージ `chiba-ai-med/wPGSAR` に置き換える。
最終形は「素の wPGSAR + 薄いアダプタ」とし、統計量の計算はすべて上流に置く。
サイト側に残すのは TSV の書き出しと階層クラスタリングだけとする。

本書は上流への貢献のみを扱う。wpgsa.org 側の採用（アダプタ、コンテナ、
インスタンスの見直し）は別の設計書とする。

## 前提とした測定

2026-08-21 に以下の条件で実測した値を本書では根拠として使う。

- 入力: `GSE63786_Kawasaki_Influenza_Virus_logFC.txt`（21,200遺伝子 × 14サンプル）
- レガシー側ネットワーク: `merged_mouse_v7_160212.network`（454 TF、260万行）
- ChIP-Atlas: `wpgsa_GRN.mm10.5.tsv`（1.01 GB、57,585,550行、19,509 SRX、869 TF）
- 測定機: Apple Silicon / 64 GB。レガシーコンテナは amd64 のためエミュレーション下

同一ネットワーク・同一入力での両実装の比較結果:

| | 値 |
|---|---|
| レガシー所要時間 / ピークメモリ | 166 秒 / 606 MiB |
| wPGSAR 所要時間 / ピークメモリ | 0.48 秒 / 約 0.4 GB |
| t 値の符号一致 | 100% |
| pearson / spearman中央値 | 0.956 / 0.938 |
| \|t\| 上位20の一致率（中央値） | 0.33 |

相関が高いのに上位が入れ替わる原因は標準誤差の分母ひとつに特定済みである。
レガシーはネットワーク上の標的遺伝子数 `size`、wPGSAR は発現データと共有する
遺伝子上の重み合計 `Σw` を使う。比 `sqrt(size/Σw)` は 0.71〜3.77 の範囲で
TF ごとに異なり、実測の t 値比の分位数と完全に一致した。

## 全体の並び

議論の要否で順序を決める。

```
issue #1  統計定義の確認（分母、検定の向き）      PR5 のみを止める
PR0  テスト基盤と CI の整備                      議論不要
PR1  事実誤りとパッケージ整備                    議論不要
PR2  性能とメモリ                                振る舞い不変
PR3  サンプルごとの p 値・q 値                   戻り値への追加、後方互換
PR4  TF単位への集約と k/n 重み                   新しい引数、既定は現行維持
PR5  標準誤差の分母                              issue #1 の結論待ち
```

PR0 から PR4 は互いに独立しており、順不同でレビューできる。
PR5 だけが issue #1 に依存する。

## issue #1: 統計定義の確認

原論文 Kawakami et al., NAR 2016 (doi:10.1093/nar/gkw355) の Materials and Methods を
当たったところ、t 統計量の分母について "n as the total number of target genes" と
読める記述があった。ただし数式が画像として埋め込まれており、
テキストとして確認できていない。断定できないため上流で確認する。

聞くのは2点である。

1. t 統計量の分母は標的遺伝子数 n か、重み合計 Σw か。
   n であればレガシー実装が定義どおりで、wPGSAR が論文から外れていることになる
2. 帰無仮説は "the weighted mean LFCs ... are equal to that of the background" と
   読め、これは両側である。レガシー実装の `scipy.stats.t.sf(abs(t), df)` は片側なので、
   当時からの誤りだったのか、意図的なものか

Kawakami 氏は原論文と wPGSAR の双方の著者であるため、この場で決着させられる。

## PR0: テスト基盤と CI の整備

以降の PR がすべてこの基盤の上に乗るため、最初に出す。
現状では後続 PR のテストを足しても CI では一度も実行されないため、
この PR は他のどれよりも先に必要である。

### CI が PR のコードを検査していない

`.github/workflows/build_test_push.yml` は `docker build` を実行するだけであり、
その `Dockerfile` は次のように書かれている。

```dockerfile
RUN R -e "... devtools::install_github('chiba-ai-med/wPGSAR', \
    upgrade='always', force=TRUE, INSTALL_opts = '--install-tests');\
    tools::testInstalledPackage('wPGSAR')"
```

チェックアウトしたソースではなく GitHub の `main` からインストールするため、
PR で変更したコードは CI で一度も実行されない。
`tools::testInstalledPackage` はテスト失敗時も非ゼロ終了しないため、
仮にソースを見ていたとしても失敗はビルドを止めない。

変更点:

- `R CMD build` と `R CMD check` を `bioconductor/bioconductor_docker:RELEASE_3_20` 上で
  チェックアウトしたソースに対して実行するワークフローを追加する
- `Dockerfile` をローカルソースからのインストールに変える
  （`COPY . /wPGSAR` と `R CMD INSTALL --install-tests /wPGSAR`）

### PR ビルドが latest を上書きしている

同ワークフローは `on: pull_request` でも `ghcr.io/<owner>/wpgsar:latest` を push する。
PR のビルドが公開タグを差し替えてしまう。

変更点:

- push は `main` への push と `workflow_dispatch` のときだけに限定し、
  `pull_request` ではビルドと検査までとする

### 非推奨の記法

- `::set-output` は GitHub 側で廃止済みであり、`$GITHUB_OUTPUT` に置き換える
- `actions/checkout@v2`、`docker/login-action@v1`、`docker/build-push-action@v1` を
  現行のメジャーバージョンに更新する

### テストの構造

`tests/testthat/*.R` は `test_that()` ブロックを使わず裸の `expect_*` を
並べているため、失敗しても どのテストが落ちたか出力されない。
また `test-retrieveNetworkData.R` は CI で実際に 1.2 GB を取得しに行く。

変更点:

- 既存のアサーションを `test_that()` ブロックに包み、期待する振る舞いを名前にする
- `retrieveNetworkData` のテストを小さなフィクスチャに差し替え、
  実ダウンロードを伴うものは `skip_on_ci()` を付ける

## PR1: 事実誤りとパッケージ整備

いずれも独立しており、レビューは読むだけで済む。

| 箇所 | 現状 | 修正 |
|---|---|---|
| `retrieveNetworkData` | `assembly="hg19"` が hg38 の URL を取得する | 引数を `c("hg38", "mm10")` に変更。`hg19` は非推奨として受理し hg38 に委譲する。既定で返るデータは従来と同じ hg38 のままであり、変わるのはその呼び名だけである |
| 同 | mm10 を `stop("Mouse Data (mm10) is not available for now...")` で拒否する | URL を追加する。`wpgsa_GRN.mm10.5.tsv`（1.01 GB）と `wpgsa_hash.mm10.5.tsv`（794 KB）はいずれも取得を確認済み |
| `man/wPGSA.Rd` | `test.method` の既定を "t" と記載 | 実装の既定は "lm"。記述を実装に合わせる |
| `.checkwPGSA` | エラー文が `nrow(expression_data)` と言いながら `ncol` を検査する | 文言を修正する |
| `DESCRIPTION` | `VignetteBuilder: knitr` を宣言しているが `vignettes/` が存在しない | vignette を追加する。Bioconductor の必須要件。`R CMD check` はこれを NOTE として報告する（実測）。失敗ではないため「check を通らない」は誤りで、Bioconductor 投稿時に問題になるのが正確な位置づけである |
| `inst/NEWS` | `VERSION 0.99.1` の項が2回ある | 重複を削除する |

`hg19` の扱いは非推奨警告つきの委譲とする。現に hg38 のデータを返してきた以上、
既存利用者のコードを黙って壊さないためである。

## PR2: 性能とメモリ

### 変更内容

ネットワークの2つの名前列を factor で保持し、フィルタと索引付けを整数コード上で行う。
5,758万要素の文字列ベクトルを一度も作らないことが要点である。

具体的には次の3点になる。

1. `retrieveNetworkData` で `read.delim` を `data.table::fread(stringsAsFactors = TRUE)` に
   置き換える
2. 実験ごとのラベル `paste(TF, celltype1, celltype2, SRX_id, sep="_")` を
   5,758万行ではなく 19,509行（SRX の水準）に対して1回だけ構築し、
   factor の水準として与える
3. `.filterwPGSA` の `network_data$GeneName %in% commonGeneName` を水準単位の
   判定に変える。factor に `%in%` を掛けると character に変換されるため、
   現状ここでも 5,758万要素の文字列ベクトルが作られている

あわせて `global_var <- apply(expression_data, 2, var)` を Matrix 対応の計算に置き換える。
`apply` は S4 オブジェクトに対して `as.matrix` を呼ぶため、疎行列を渡すと密化する。
13 KB の疎行列に対して 195 MB を確保することを実測した。
0.99.1 で謳った疎行列対応が、背景統計量の計算では効いていない。

### 実測値

ChIP-Atlas mm10 全体、同一の入力・同一の出力での比較:

| | 現行実装 | PR2 適用後 |
|---|---|---|
| 所要時間 | 23.4 秒 | 8.4 秒 |
| ピーク RSS | 7.86 GB | 4.93 GB |

t 統計量は現行と最大絶対差 1.4e-13 で一致する。

この「現行実装」の側は `fread` で読んだ場合の値である。
`retrieveNetworkData` が実際に使う `read.delim` + `dplyr::left_join` の経路は
ネットワーク構築だけで 27.8 秒 / ピーク RSS 7.16 GB を要し、
その上に `wPGSA()` の実行が乗る。
つまり上の比較は上流に有利な側に寄せた見積もりであり、実際の改善幅はこれより大きい。
PR の説明では両方の数値を示す。

### 保持すべき挙動

現行の `.filterwPGSA` は共通遺伝子で絞り込んだ後に `unique(network_data$TF_name)` を
取るため、標的遺伝子が発現データに1つも無い TF が結果から落ちる。
mm10 では 19,509 SRX のうち 5 件が該当した。
この取りこぼしは意図された挙動として維持し、テストで固定する。
素直に書き直すと NaN 行として残ってしまうため、明示的に扱う必要がある。

## PR3: サンプルごとの p 値・q 値

### API

```r
wPGSA(network_data, expression_data, group = NULL,
      test.method = c("lm", "wilcox"),
      alternative = c("two.sided", "greater", "less"))
```

戻り値に `tstat_pval` と `tstat_fdr` を追加する。
既存の `pval` / `fdr` はグループ間検定の結果であり意味が異なるため、名前を分ける。
`tstat` / `tstat_se` と対になる命名とする。

`alternative` の既定は `"two.sided"` とする。論文の帰無仮説が両側であり、
R の `t.test` / `wilcox.test` の作法にも沿う。

レガシー実装の p 値は `scipy.stats.t.sf(abs(t_score), df)` であり、
絶対値を取っているため `alternative = "greater"` とは一致しない
（t が負のとき `greater` は 0.5 を超えるが、レガシーは常に 0.5 未満を返す）。
実体は両側 p 値のちょうど半分である。
したがってレガシー互換のための引数は追加せず、
ゴールデンテストは「両側 p 値の半分がレガシーの出力と一致する」ことで書く。

`tstat_fdr` はサンプルごとに Benjamini-Hochberg 補正を掛ける。
レガシー実装が時点ごとに `p.adjust(method="BH")` を掛けていたのと同じ単位である。

### 自由度と `n_eff`

自由度は Welch-Satterthwaite による。レガシー実装は次を使う。

```
df = (n - 1) * (v_bg + v_target)^2 / (v_bg^2 + v_target^2)
```

この `n` は標準誤差の分母と同じ量であり、issue #1 の結論に依存する。
そこで PR3 では、標準誤差と自由度の双方が参照する内部量を `n_eff` として
1箇所に集約する。PR5 は `n_eff` の定義を変えるだけになり、
issue #1 の決着を待たずに PR3 を出せる。

`n_eff` の候補は2つではなく3つある点に注意する。

| 候補 | 定義 | 使っているもの |
|---|---|---|
| `weights` | 共通遺伝子上の重み合計 Σw | wPGSAR の現行 |
| `targets` | 共通遺伝子上の標的遺伝子数 | どちらでもない |
| `targets_all` | ネットワーク全体での標的遺伝子数 | レガシー実装 |

レガシーは発現データに存在しない標的遺伝子まで数に含めるため `targets_all` になる。
相互参照フィクスチャを再現するにはこの区別が要る。
`targets_all` は絞り込み前のネットワークから計算する必要があるため、
`n_eff` を求める関数は絞り込み前後の双方を受け取る形にする。
既定は issue #1 が決着するまで `weights`（現行の振る舞い）を維持する。

## PR4: TF単位への集約と k/n 重み

### 背景

wPGSAR は `network_data$weight <- 1` と固定しており、スコアを TF 単位ではなく
実験（SRX）単位で出す。論文の中核である「TF が k 回中 n 回結合した遺伝子を
確率 k/n で制御する」という重み付けが失われている。
`weight` が全て1であれば、それは重み付きでない解析である。

ChIP-Atlas の配布形式は SRX と遺伝子の対であり、k/n はそこから再構成できる。
2016年版ネットワークもそのようにして作られたものである。

### API

```r
retrieveNetworkData(assembly = c("hg38", "mm10"),
                    resolution = c("experiment", "TF"))
```

既定は `"experiment"` とし、既存利用者の数値は動かさない。
`"TF"` では TF ごとに、その TF の全 ChIP 実験数 n と、
対象遺伝子が結合していた実験数 k から `weight = k / n` を作り、
`TF_name` を TF のシンボルとする。

### 実測値

mm10 での構築結果:

- 57,585,550 件の結合イベント → 5,928,646 件の TF-遺伝子ペア（869 TF）。実験単位の約10分の1
- 構築 4.5 秒、ピーク RSS 3.4 GB、`wPGSA()` 本体 0.22 秒
- 重みの範囲 0.0007〜1、平均 0.324

2016年版ネットワークとの照合:

- 454 TF 中 413 TF が現在も存在する
- 共有する 1,752,252 ペアで重みの相関は pearson 0.515 / spearman 0.536
- TF あたりの実験数は中央値 3 → 14、最大 116 → 1435

相関が 0.5 程度であるのは、同じ量をはるかに多くの実験から推定し直しているためである。
乖離ではなく更新として PR の説明に書く。

集約後のネットワークは 592万行であり、TSV で 120 MB 程度に収まる。
1.01 GB を毎回読む必要がなくなる点で、下流の利用者にも意味がある。

## PR5: 標準誤差の分母

issue #1 の結論により3通りに分岐する。

- 分母が n（標的遺伝子数）と確定した場合: `n_eff` の定義変更とテストのみ
- Σw が正しいと確定した場合: PR5 は不要。代わりに wpgsa.org 側の理解を改める
- 決着しない場合: `se.denom = c("targets", "weights")` を追加し、利用者に選ばせる

## 検証戦略

### 数値の同一性（PR2）

現行実装と新実装を同じ入力で走らせ、最大絶対差が 1e-10 未満であることを固定する。
「標的遺伝子が発現データに1つも無い TF は結果に含まれない」ことも併せてテストする。

時間とメモリの測定値は PR の説明に載せるだけとし、CI には持ち込まない。
測定機の性能に依存する数値をテストにすると偽陽性の元になる。

### 相互参照フィクスチャ（PR3）

`merged_mouse_v7_160212.network` を 20 TF 程度、サンプル入力を 500 遺伝子程度に
切り詰めたものを 2016年のコンテナ `inutano/wpgsa:0.5.2` に通し、
入力と出力の対を `inst/extdata` に置く。

wPGSAR 側はレガシーの分母設定でこれを再現できなければならない、
というゴールデンテストとする。t 値は直接比較し、
p 値は「両側 p 値の半分がレガシーの出力と一致する」ことで比較する。
論文実装との一致が回帰テストとして固定され、
今回のような食い違いが静かに入ることを防げる。

フィクスチャの生成手順自体もリポジトリに含め、再生成可能にする。

### 不変量（PR4）

集約後の全行で `0 < weight <= 1` を検査する。結合頻度であるから1を超えられない。
これは 2026-08-21 に wpgsa.org 側でネットワークの列ずれを検出したのと同じ性質であり、
上流でも同じ罠を塞ぐ。

### 主張しないこと

ネットワークを2016年版から ChIP-Atlas に置き換えると、解像度と重み付けを揃えても
結果は相当に変わる。共有 413 TF での実測は次のとおりである。

| | 値 |
|---|---|
| pearson | 0.798 |
| spearman（中央値） | 0.535 |
| \|t\| 上位20の一致率（中央値） | 0.15 |
| 符号一致 | 0.822 |

エンジンの入れ替えよりネットワークの更新の方が結果を大きく動かす。
これはソフトウェアの正しさの問題ではなく生物学的な検証の問題であるため、
上流 PR の守備範囲から外す。
PR がネットワーク更新を検証したかのように読まれないよう、説明に明記する。

## 対象外

- wpgsa.org 側のアダプタ、コンテナ、インスタンスの見直し（別の設計書とする）
- 2016年版ネットワークから ChIP-Atlas への更新の生物学的な妥当性検証
- `test.method` に関する変更。現状の `lm` / `wilcox` はサイトの用途と独立している

## 未解決事項

- issue #1 の結論。PR5 の内容と PR3 の自由度の確定がこれに依存する
- PR4 で TF 単位に集約する際、細胞種をまたいで集約してよいか。
  2016年版は TF 単位で集約しているため既定はそれに倣うが、
  `resolution = "TF_celltype"` の需要があるかは著者に確認する
- vignette の題材。ChIP-Atlas からの取得を含めると vignette のビルドに
  1.2 GB のダウンロードが要る。キャッシュ済みの小さなフィクスチャで
  代替できるか確認する
