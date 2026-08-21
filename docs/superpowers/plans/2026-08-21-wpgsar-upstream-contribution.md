# wPGSAR 上流貢献 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `chiba-ai-med/wPGSAR` に一連の PR を出し、wpgsa.org が「素の wPGSAR + 薄いアダプタ」で動く土台を作る。

**Architecture:** 独立にレビューできる PR に分割する。CI が PR のコードを検査していないため、それを直す PR0 を最初に出す。統計定義の確認は issue として非同期に走らせ、それに依存する PR5 だけを最後に置く。

**Tech Stack:** R 4.4 / Bioconductor 3.20、`data.table`、`Matrix`、`BiocFileCache`、`testthat` 3e、GitHub Actions、Docker

**Spec:** `docs/superpowers/specs/2026-08-21-wpgsar-upstream-contribution-design.md`

## Global Constraints

- 対象リポジトリは `chiba-ai-med/wPGSAR`、既定ブランチは `main`。作業者の GitHub アカウント `inutano` は ADMIN 権限を持つためフォークは不要で、リポジトリ内にブランチを切って PR を出す。
- **PR と issue の作成は、その都度ユーザーの合図を待つこと。** 相手のプロジェクトへの外向きの操作であり、ブランチを push するところまでを自動で進めてよい。
- 上流リポジトリでのコミットメッセージと PR 本文は英語で書く。この計画書と設計書は日本語で保持する。
- パッケージのバージョンは Bioconductor 投稿前の慣行に従い `0.99.x` を維持する。各 PR で `DESCRIPTION` の `Version` を1つ上げ、`inst/NEWS` に項目を追加する。
- 既存の公開 API を壊さない。`wPGSA()` と `retrieveNetworkData()` の既定の振る舞いは、PR5 まで一切変えない。
- `network_data` はユーザーが自分で組み立てて渡せる引数である。内部関数は `TF_name` / `GeneName` が factor でも character でも動かなければならない。
- 数値の同一性を主張するテストの許容差は `1e-10` とする。
- 作業ディレクトリは `~/repos/wPGSAR`。ChIP-Atlas の実データは `~/data/chip-atlas/` に置く。
- コード内コメントとコミットメッセージに現れる `#<N>` と `issues/<N>` は、Task 2 で作成した issue の番号に置き換える。番号は `.dev/baseline.md` に控えてある。

---

## File Structure

上流リポジトリで作成・変更するファイル。

| ファイル | 責務 | 触る PR |
|---|---|---|
| `.github/workflows/check.yml` | 新規。チェックアウトしたソースに対する `R CMD check` と testthat | PR0 |
| `.github/workflows/build_test_push.yml` | 既存。push の条件を絞り、非推奨 action を更新 | PR0 |
| `Dockerfile` | 既存。GitHub からではなくローカルソースからインストールする | PR0 |
| `tests/testthat/test-wPGSA.R` | 既存。`test_that()` に包む | PR0 |
| `tests/testthat/test-retrieveNetworkData.R` | 既存。フィクスチャ化と `skip_on_ci()` | PR0 |
| `tests/testthat/helper-wPGSA.R` | 既存。フィクスチャの定義を集約 | PR0, PR4 |
| `R/retrieveNetworkData.R` | assembly の呼称、mm10、factor 表現、`resolution` 引数 | PR1, PR2, PR4 |
| `R/wPGSA.R` | 索引付け、背景分散、`n_eff`、p 値 | PR2, PR3, PR5 |
| `man/*.Rd` | roxygen2 による再生成 | PR1, PR3, PR4 |
| `vignettes/wPGSAR.Rmd` | 新規。Bioconductor 必須要件 | PR1 |
| `inst/extdata/legacy/` | 新規。相互参照フィクスチャ | PR3 |
| `inst/NEWS` | 重複の削除と各 PR の項目追加 | 全 PR |
| `DESCRIPTION` | `Imports` の調整とバージョン | PR1, PR2 |

wpgsa.org リポジトリ側で作成するファイル。

| ファイル | 責務 |
|---|---|
| `script/build-legacy-fixture.sh` | 相互参照フィクスチャをレガシーコンテナから再生成する手順 |

---

### Task 1: 開発環境とベースラインの記録

上流のコードに触る前に、変更前の状態を測って残す。以降のすべての PR がこのベースラインとの差分で語られる。

**Files:**
- Create: `~/repos/wPGSAR`（クローン）
- Create: `~/data/chip-atlas/wpgsa_GRN.mm10.5.tsv`, `~/data/chip-atlas/wpgsa_hash.mm10.5.tsv`
- Create: `~/repos/wPGSAR/.dev/Dockerfile.dev`（コミットしない。`.git/info/exclude` に追加）
- Create: `~/repos/wPGSAR/.dev/baseline.md`（コミットしない）

**Interfaces:**
- Produces: `wpgsar-dev` という名前のローカル Docker イメージ。以降のすべてのタスクがテスト実行に使う
- Produces: `~/.dev/baseline.md` に記録した変更前の `R CMD check` の結果と実測値

- [ ] **Step 1: リポジトリをクローンする**

```bash
mkdir -p ~/repos && cd ~/repos
git clone https://github.com/chiba-ai-med/wPGSAR.git
cd wPGSAR && git log --oneline -3
```

- [ ] **Step 2: ChIP-Atlas のデータを配置する**

すでに手元にあるなら再取得しない。無い場合のみ取得する（合計約 1.01 GB）。

```bash
mkdir -p ~/data/chip-atlas && cd ~/data/chip-atlas
[ -f wpgsa_GRN.mm10.5.tsv ] || curl -O https://chip-atlas.dbcls.jp/data/mm10/wpgsa/wpgsa_GRN.mm10.5.tsv
[ -f wpgsa_hash.mm10.5.tsv ] || curl -O https://chip-atlas.dbcls.jp/data/mm10/wpgsa/wpgsa_hash.mm10.5.tsv
[ -f logfc.txt ] || curl -sL -o logfc.txt \
  https://raw.githubusercontent.com/eiryo-kawakami/wPGSA/master/sample_logFC_file/GSE63786_Kawasaki_Influenza_Virus_logFC.txt
wc -l wpgsa_GRN.mm10.5.tsv logfc.txt
```

期待: `57585550 wpgsa_GRN.mm10.5.tsv` と `21201 logfc.txt`

Docker Desktop に割り当てたメモリが 12 GB 未満だと、この後の変更前の測定が
OOM で落ちる。設定を確認してから進める。

```bash
docker info --format '{{.MemTotal}}' | awk '{printf "docker memory: %.1f GB\n", $1/1024/1024/1024}'
```

- [ ] **Step 3: 開発用イメージを作る**

上流の CI と同じ土台を使う。`bioconductor/bioconductor_docker:RELEASE_3_20` は arm64 のマニフェストを持つため、Apple Silicon でもエミュレーションなしで動く。

```bash
mkdir -p ~/repos/wPGSAR/.dev
cat > ~/repos/wPGSAR/.dev/Dockerfile.dev <<'EOF'
FROM bioconductor/bioconductor_docker:RELEASE_3_20
RUN R -q -e "BiocManager::install('BiocFileCache', ask=FALSE, update=FALSE); \
             install.packages(c('data.table','dplyr','testthat','roxygen2','devtools'))"
EOF
echo ".dev/" >> ~/repos/wPGSAR/.git/info/exclude
cd ~/repos/wPGSAR && docker build -t wpgsar-dev -f .dev/Dockerfile.dev .dev
```

- [ ] **Step 4: 変更前の R CMD check を実行して結果を残す**

```bash
cd ~/repos/wPGSAR
docker run --rm -v "$PWD:/work" -w /work wpgsar-dev \
  bash -c "R CMD build --no-build-vignettes . && R CMD check --no-manual wPGSAR_*.tar.gz" \
  2>&1 | tee .dev/baseline-check.log | tail -30
```

期待: `VignetteBuilder: knitr` を宣言しながら `vignettes/` が無いことによる WARNING または ERROR が出る。これが PR1 で直す対象である。出力を `.dev/baseline-check.log` に残す。

- [ ] **Step 5: 変更前の性能を測って残す**

```bash
cd ~/repos/wPGSAR
cat > .dev/baseline_perf.R <<'EOF'
suppressPackageStartupMessages({library(dplyr)})
mem <- function(tag) cat(sprintf("[mem] %-22s R max used: %.0f MB\n", tag,
  sum(gc(FALSE)[, "max used"] * c(8,8))/1e6))
t0 <- proc.time()
tmp1 <- read.delim("/data/wpgsa_GRN.mm10.5.tsv", header=FALSE)
tmp2 <- read.delim("/data/wpgsa_hash.mm10.5.tsv", header=FALSE)
colnames(tmp1) <- c("SRX_id","GeneName")
colnames(tmp2) <- c("SRX_id","TF","celltype1","celltype2")
network_data <- left_join(tmp1, tmp2, by="SRX_id")
network_data$TF_name <- paste(network_data$TF, network_data$celltype1,
  network_data$celltype2, network_data$SRX_id, sep="_")
network_data$weight <- 1
network_data <- network_data[, c("TF_name","GeneName","weight")]
cat("elapsed:", (proc.time()-t0)[["elapsed"]], "s  rows:", nrow(network_data), "\n")
mem("after network_data")

# The before-state result, so later tasks can prove they did not move the
# numbers without checking main out again -- main refuses mm10 until PR1
# lands, so retrieveNetworkData() is not usable for this comparison.
devtools::load_all("/work")
expr <- as.matrix(read.delim("/data/logfc.txt", row.names=1, check.names=FALSE))
saveRDS(as.matrix(wPGSA(network_data, expr)$tstat), "/data/tstat_before.rds")
cat("saved tstat_before.rds\n")
EOF
docker run --rm -v "$PWD:/work" -v "$HOME/data/chip-atlas:/data" -w /work wpgsar-dev \
  bash -c "/usr/bin/time -v Rscript .dev/baseline_perf.R" 2>&1 | \
  grep -E "elapsed|\[mem\]|Maximum resident" | tee -a .dev/baseline.md
```

期待: 25秒前後、Maximum resident set size が 7 GB 前後。手元の測定では 27.8 秒 / 7.16 GB だった。値が大きく違う場合は環境差を `.dev/baseline.md` に注記してから先へ進む。

- [ ] **Step 6: コミットは不要**

`.dev/` は `.git/info/exclude` で除外済みである。上流に何も足していないことを確認する。

```bash
cd ~/repos/wPGSAR && git status --short
```

期待: 出力が空。

---

### Task 2: issue #1 を立てる

PR5 の内容がこの結論に依存する。返答を待つ間に他の PR を進められるよう、最初に投げる。

**Files:**
- 変更なし（GitHub 上の issue のみ）

**Interfaces:**
- Produces: issue 番号。Task 8 のコード内コメントと Task 10 が参照する

- [ ] **Step 1: 本文を用意する**

`~/repos/wPGSAR/.dev/issue-1.md` に書く。

```markdown
## Which quantity does the published t-statistic divide by?

I am adapting wpgsa.org to use wPGSAR as its engine, and comparing the two
implementations on identical input and an identical network turned up one
systematic difference. I would rather confirm the intent than guess.

`wPGSA()` computes the standard error as

```r
tstat_se <- sqrt(t(global_var + t(target_var)) / total_sum)
# total_sum <- rowSums(network_sparse)
```

so the denominator is the sum of weights over the genes shared between the
network and the expression matrix. The 2016 Python implementation
(`eiryo-kawakami/wPGSA`) instead divides by `size`, the number of target genes
the TF has in the whole network -- including genes the expression matrix never
measured.

Reading the Materials and Methods of the NAR paper, the sentence around the
t-statistic describes `n` as the total number of target genes, which would
make the Python version the one that matches the paper. The equations are
embedded as images, so I could not confirm this from the text.

The two are not a constant factor apart. On GSE63786 against the 2016 mouse
network the ratio `sqrt(size / total_sum)` ranges from 0.71 to 3.77 across
TFs. Sign agreement stays at 100% and Pearson correlation at 0.956, but only
about a third of each sample's top-20 TFs by |t| survive the change -- which
is the part a user actually reads.

Two questions:

1. Should the denominator be the target-gene count or the sum of weights?
2. The paper states the null hypothesis as the weighted mean LFC of the
   target genes being equal to the background, which is two-sided. The Python
   implementation reports `scipy.stats.t.sf(abs(t_score), df)`, exactly half
   of the two-sided p-value. Was that deliberate?

Happy to send a PR either way once it is settled.
```

- [ ] **Step 2: ユーザーの合図を待ってから issue を作成する**

これは相手のプロジェクトへの外向きの操作である。承認を得てから実行する。

```bash
cd ~/repos/wPGSAR
gh issue create --repo chiba-ai-med/wPGSAR \
  --title "Which quantity does the published t-statistic divide by?" \
  --body-file .dev/issue-1.md
```

- [ ] **Step 3: issue 番号を記録する**

`.dev/baseline.md` に番号を追記する。Task 8 のコメントと Task 10 が参照する。

---

### Task 3: PR0-a — CI がチェックアウトしたソースを検査するようにする

これを先に直さないと、以降の PR で足すテストは CI で一度も動かない。

**Files:**
- Create: `.github/workflows/check.yml`
- Modify: `Dockerfile`
- Modify: `.github/workflows/build_test_push.yml`

**Interfaces:**
- Produces: PR ごとに `R CMD check` と testthat が走る CI。以降のすべてのタスクがこれに依存する

- [ ] **Step 1: ブランチを切る**

```bash
cd ~/repos/wPGSAR && git checkout main && git pull --ff-only
git checkout -b ci-check-the-code-under-review
```

- [ ] **Step 2: 現状の Dockerfile が main を見ていることを確認する**

```bash
cat Dockerfile
```

期待: `devtools::install_github('chiba-ai-med/wPGSAR', ...)` が含まれる。ローカルの `COPY` は無い。これが「PR のコードが検査されない」根拠である。

- [ ] **Step 3: Dockerfile をローカルソースからのインストールに変える**

```dockerfile
# Base Image
FROM bioconductor/bioconductor_docker:RELEASE_3_20

# Install Dependencies
RUN R -e "BiocManager::install(version = '3.20'); \
    BiocManager::install('BiocFileCache', update = TRUE, ask = FALSE)"

# Install wPGSAR from this checkout, not from GitHub: an image built for a
# pull request must contain the code under review.
COPY . /wPGSAR
RUN R CMD INSTALL --install-tests /wPGSAR \
    && R -e "if (!all(vapply(tools::testInstalledPackage('wPGSAR'), identical, logical(1), 0L))) quit(status = 1)"
```

`tools::testInstalledPackage` は失敗しても非ゼロで終了しないため、戻り値を見て明示的に落とす。

- [ ] **Step 4: R CMD check のワークフローを新規に追加する**

`.github/workflows/check.yml`:

```yaml
name: R CMD check

on:
  push:
    branches: [ main ]
  pull_request:
    branches: [ main ]
  workflow_dispatch:

jobs:
  check:
    runs-on: ubuntu-latest
    container:
      image: bioconductor/bioconductor_docker:RELEASE_3_20
    steps:
      - uses: actions/checkout@v4

      - name: Install dependencies
        run: |
          R -q -e "BiocManager::install('BiocFileCache', ask = FALSE, update = FALSE)"
          R -q -e "install.packages(c('data.table', 'dplyr', 'testthat', 'knitr', 'rmarkdown'))"

      - name: Build
        run: R CMD build .

      - name: Check
        run: R CMD check --no-manual wPGSAR_*.tar.gz

      - name: Show check log on failure
        if: failure()
        run: cat wPGSAR.Rcheck/00check.log
```

- [ ] **Step 5: PR ビルドが latest を上書きしないようにする**

`.github/workflows/build_test_push.yml` の `on:` から `pull_request` を外し、build ジョブと push ジョブを分ける。あわせて非推奨の記法を更新する。

```yaml
name: DockerHub/GHCR

env:
  IMAGE_NAME: wpgsar
  repo-name: koki/wpgsar

on:
  push:
    branches: [ main ]
  pull_request:
    branches: [ main ]
  workflow_dispatch:

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Declare some variables
        id: vars
        shell: bash
        run: echo "sha_short=$(git rev-parse --short HEAD)" >> "$GITHUB_OUTPUT"

      - name: Build
        run: docker build -t ${{ github.repository_owner }}/${{ env.IMAGE_NAME }} .

      # Publishing is deliberately skipped for pull requests: a build for a
      # proposed change must not replace the tag users pull.
      - name: Login to GitHub Container Registry
        if: github.event_name != 'pull_request'
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Tag and push
        if: github.event_name != 'pull_request'
        run: |
          docker tag ${{ github.repository_owner }}/${{ env.IMAGE_NAME }} ghcr.io/${{ github.repository_owner }}/${{ env.IMAGE_NAME }}:latest
          docker tag ${{ github.repository_owner }}/${{ env.IMAGE_NAME }} ghcr.io/${{ github.repository_owner }}/${{ env.IMAGE_NAME }}:${{ steps.vars.outputs.sha_short }}
          docker push ghcr.io/${{ github.repository_owner }}/${{ env.IMAGE_NAME }}:latest
          docker push ghcr.io/${{ github.repository_owner }}/${{ env.IMAGE_NAME }}:${{ steps.vars.outputs.sha_short }}
```

`docker/build-push-action@v1` を使った最後のステップは削除する。同じイメージを二重に push しており、`tag_with_ref` は v1 にしか無い機能である。Docker Hub への公開を続けたい場合は `if: github.event_name != 'pull_request'` を付けた上で `docker/login-action` と `docker push` に統一する。この判断は PR の説明で著者に確認する。

- [ ] **Step 6: PR のコードが実際に検査されることを、失敗させて確かめる**

わざとテストを1つ壊し、CI が赤くなることを確認する。これを見ないと「CI が動くようになった」と言えない。

```bash
cd ~/repos/wPGSAR
printf '\nexpect_equal(1, 2)\n' >> tests/testthat/test-wPGSA.R
docker build -t wpgsar-ci-probe . 2>&1 | tail -20
```

期待: `docker build` が非ゼロで終了する。変更前の Dockerfile では、ローカルの変更が無視されるため成功していたはずである。

- [ ] **Step 7: わざと入れた失敗を戻す**

```bash
cd ~/repos/wPGSAR && git checkout tests/testthat/test-wPGSA.R
docker build -t wpgsar-ci-probe . 2>&1 | tail -5
```

期待: 成功して終了する。

- [ ] **Step 8: NEWS とバージョンを更新する**

`DESCRIPTION` の `Version: 0.99.2` を `0.99.3` にする。`inst/NEWS` の先頭に追加する。

```
VERSION 0.99.3
------------------------
   o CI now builds and tests the code under review, not the GitHub main branch
   o Images are no longer published from pull request builds
```

- [ ] **Step 9: コミットして push する**

```bash
cd ~/repos/wPGSAR
git add Dockerfile .github/workflows/check.yml .github/workflows/build_test_push.yml DESCRIPTION inst/NEWS
git commit -m "Build and test the code under review

The workflow ran docker build, and the Dockerfile installed the package
with install_github from the main branch, so a pull request's own code was
never executed. Tests added by any later change would have looked green
without ever running. Install from the checkout instead, fail the build on
a test failure, and add an R CMD check workflow.

Publishing moves behind a check for the event name. A pull request build was
pushing ghcr.io/<owner>/wpgsar:latest, replacing the tag users pull with the
contents of a proposed change."
git push -u origin ci-check-the-code-under-review
```

- [ ] **Step 10: ユーザーの合図を待ってから PR を出す**

```bash
# The commit messages in this plan are written to serve as the PR body.
gh pr create --repo chiba-ai-med/wPGSAR --base main --fill
```

---

### Task 4: PR0-b — テストの構造化とネットワーク取得の切り離し

**Files:**
- Modify: `tests/testthat/test-wPGSA.R`
- Modify: `tests/testthat/test-retrieveNetworkData.R`
- Modify: `tests/testthat/helper-wPGSA.R`
- Modify: `tests/testthat/test-GSE143371.R`

**Interfaces:**
- Consumes: Task 3 の CI
- Produces: `dummy_network_data`, `dummy_GSE143371_count`, `dummy_GSE143371_count_sparse`（`helper-wPGSA.R` で定義済み。以降のタスクが使う）

- [ ] **Step 1: ブランチを切る**

```bash
cd ~/repos/wPGSAR && git checkout main && git pull --ff-only
git checkout -b tests-name-what-they-check
```

- [ ] **Step 2: 現状のテストが失敗しても名前を出さないことを確認する**

```bash
cd ~/repos/wPGSAR
printf '\nexpect_equal(length(res1), 999)\n' >> tests/testthat/test-wPGSA.R
docker run --rm -v "$PWD:/work" -w /work wpgsar-dev \
  R -q -e 'devtools::load_all("."); testthat::test_local()' 2>&1 | tail -15
git checkout tests/testthat/test-wPGSA.R
```

期待: 失敗は報告されるが、どの振る舞いが壊れたのかを示す名前が出ない。これが直す対象である。

- [ ] **Step 3: `test-wPGSA.R` を `test_that()` に包む**

裸の `expect_*` を、検査している振る舞いごとにまとめる。

```r
test_that("wPGSA returns all seven components without group labels", {
  res <- wPGSA(dummy_network_data, dummy_GSE143371_count)
  expect_equal(length(res), 7)
  expect_true(is.null(res$group_mean))
  expect_true(is.null(res$group_se))
  expect_true(is.null(res$group_t))
  expect_true(is.null(res$pval))
  expect_true(is.null(res$fdr))
})

test_that("wPGSA fills in the group statistics when group labels are given", {
  res <- wPGSA(dummy_network_data, dummy_GSE143371_count, GSE143371_group)
  expect_equal(length(res), 7)
  expect_false(is.null(res$group_mean))
  expect_false(is.null(res$group_se))
  expect_false(is.null(res$group_t))
  expect_false(is.null(res$pval))
  expect_false(is.null(res$fdr))
})

test_that("a sparse expression matrix gives the same result as a dense one", {
  dense  <- wPGSA(dummy_network_data, dummy_GSE143371_count)
  sparse <- wPGSA(dummy_network_data, dummy_GSE143371_count_sparse)
  expect_equal(as.matrix(dense$tstat), as.matrix(sparse$tstat), tolerance = 1e-10)
})

test_that("a sparse expression matrix gives the same group statistics", {
  dense  <- wPGSA(dummy_network_data, dummy_GSE143371_count, GSE143371_group)
  sparse <- wPGSA(dummy_network_data, dummy_GSE143371_count_sparse, GSE143371_group)
  expect_equal(dense$pval, sparse$pval, tolerance = 1e-10)
})
```

3番目と4番目は元のテストより強い。元は「疎行列でも7要素返る」しか見ておらず、密と疎で同じ数になることを確かめていなかった。0.99.1 で追加された機能の本来の主張はこちらである。

- [ ] **Step 4: テストが通ることを確認する**

```bash
cd ~/repos/wPGSAR
docker run --rm -v "$PWD:/work" -w /work wpgsar-dev \
  R -q -e 'devtools::load_all("."); testthat::test_local()' 2>&1 | tail -15
```

期待: 4件すべて PASS。もし3番目か4番目が落ちるなら、それは疎行列対応に実際の欠陥があるということなので、PR2 に持ち込まず先に報告する。

- [ ] **Step 5: ネットワーク取得のテストを切り分ける**

`test-retrieveNetworkData.R` を書き換える。実ダウンロードは CI から外し、キャッシュの振る舞いは手元でだけ確認する。

```r
test_that("retrieveNetworkData returns a data frame and reuses its cache", {
  skip_on_ci()
  skip_if_offline()

  out <- retrieveNetworkData()
  expect_true(is.data.frame(out))
  expect_named(out, c("TF_name", "GeneName", "weight"))

  # The second call must come from BiocFileCache, not the network.
  out2 <- retrieveNetworkData()
  expect_identical(out, out2)

  info <- BiocFileCache::bfcinfo(BiocFileCache::BiocFileCache())
  expect_gt(nrow(info), 0)
})
```

`skip_if_offline()` は testthat 3e が提供する。`DESCRIPTION` の `Suggests` に `curl` を足す必要がある（`skip_if_offline` が使う）。

- [ ] **Step 6: CI 相当の条件でスキップされることを確認する**

```bash
cd ~/repos/wPGSAR
docker run --rm -e CI=true -v "$PWD:/work" -w /work wpgsar-dev \
  R -q -e 'devtools::load_all("."); testthat::test_local()' 2>&1 | tail -10
```

期待: スキップとして報告され、1.2 GB の取得は発生しない。実行時間が数秒で終わることで確かめられる。

- [ ] **Step 7: NEWS とバージョンを更新してコミット、push する**

`DESCRIPTION` を `0.99.4` に、`inst/NEWS` に追加する。

```bash
cd ~/repos/wPGSAR
git add tests/testthat DESCRIPTION inst/NEWS
git commit -m "Name what each test checks, and stop downloading 1.2 GB in CI

The assertions sat at the top level of each file rather than inside
test_that blocks, so a failure reported the expectation but not the
behaviour it belonged to.

The sparse-matrix tests only asserted that seven components came back. They
now assert that sparse and dense input produce the same numbers, which is
what sparse support claims.

test-retrieveNetworkData.R fetched the real 1.2 GB network from ChIP-Atlas
on every CI run. That check is worth keeping, but not there."
git push -u origin tests-name-what-they-check
```

- [ ] **Step 8: ユーザーの合図を待ってから PR を出す**

---

### Task 5: PR1 — 事実誤りとパッケージ整備

**Files:**
- Modify: `R/retrieveNetworkData.R`
- Modify: `R/wPGSA.R`（`.checkwPGSA` のエラー文のみ）
- Create: `vignettes/wPGSAR.Rmd`
- Modify: `inst/NEWS`
- Modify: `DESCRIPTION`
- Regenerate: `man/*.Rd`

**Interfaces:**
- Produces: `retrieveNetworkData(assembly = c("hg38", "mm10"))`。Task 10 がこの引数リストに `resolution` を足す

- [ ] **Step 1: ブランチを切る**

```bash
cd ~/repos/wPGSAR && git checkout main && git pull --ff-only
git checkout -b fix-assembly-names-and-package-metadata
```

- [ ] **Step 2: assembly の呼称と mm10 について、失敗するテストを書く**

`tests/testthat/test-retrieveNetworkData.R` に追加する。

```r
test_that("the assembly argument names the assembly the URLs actually serve", {
  # The default has always fetched the hg38 files; only the label was wrong.
  expect_equal(eval(formals(retrieveNetworkData)$assembly), c("hg38", "mm10"))
})

test_that("hg19 is still accepted, with a deprecation warning", {
  skip_on_ci()
  skip_if_offline()
  expect_warning(retrieveNetworkData("hg19"), "hg38")
})

test_that("mm10 is available", {
  expect_silent(wPGSAR:::.networkURLs("mm10"))
  urls <- wPGSAR:::.networkURLs("mm10")
  expect_match(urls$grn, "wpgsa_GRN\\.mm10\\.5\\.tsv$")
  expect_match(urls$hash, "wpgsa_hash\\.mm10\\.5\\.tsv$")
})
```

- [ ] **Step 3: テストが失敗することを確認する**

```bash
cd ~/repos/wPGSAR
docker run --rm -v "$PWD:/work" -w /work wpgsar-dev \
  R -q -e 'devtools::load_all("."); testthat::test_local()' 2>&1 | tail -20
```

期待: 3件とも失敗する。`.networkURLs` は存在しないため「could not find function」で落ちる。

- [ ] **Step 4: URL の選択を関数に切り出して実装する**

`R/retrieveNetworkData.R` の冒頭部分を置き換える。

```r
.networkURLs <- function(assembly){
	base <- "https://chip-atlas.dbcls.jp/data"
	switch(assembly,
		hg38 = list(
			grn  = paste0(base, "/hg38/wpgsa/wpgsa_GRN.hg38.5.tsv"),
			hash = paste0(base, "/hg38/wpgsa/wpgsa_hash.hg38.5.tsv")),
		mm10 = list(
			grn  = paste0(base, "/mm10/wpgsa/wpgsa_GRN.mm10.5.tsv"),
			hash = paste0(base, "/mm10/wpgsa/wpgsa_hash.mm10.5.tsv")))
}

retrieveNetworkData <- function(assembly=c("hg38", "mm10"),
	out.dir=tempdir()){
	# "hg19" selected the hg38 files, so the label was the only thing wrong.
	# Accept it rather than break callers, and say what they are getting.
	if(identical(assembly, "hg19")){
		warning("assembly = \"hg19\" is deprecated: these files are hg38. ",
			"Using assembly = \"hg38\".")
		assembly <- "hg38"
	}
	assembly <- match.arg(assembly)
	urls <- .networkURLs(assembly)
	url1 <- urls$grn
	url2 <- urls$hash
	...
}
```

以降の `bfcquery` から下は変更しない。

- [ ] **Step 5: テストが通ることを確認する**

```bash
cd ~/repos/wPGSAR
docker run --rm -e CI=true -v "$PWD:/work" -w /work wpgsar-dev \
  R -q -e 'devtools::load_all("."); testthat::test_local()' 2>&1 | tail -15
```

期待: すべて PASS（`hg19` のテストは `skip_on_ci` でスキップ）。

- [ ] **Step 6: エラー文の取り違えを直す**

`R/wPGSA.R` の `.checkwPGSA` を修正する。

```r
		if(ncol(expression_data) != length(group)){
			stop("ncol(expression_data) and length(group) must be the same value!")
		}
```

- [ ] **Step 7: Rd の既定値の記述を直す**

`R/wPGSA.R` の roxygen コメントを修正する。

```r
#' @param test.method Test method to perform statistical tests to compare TF activity between groups (Default: "lm").
```

- [ ] **Step 8: vignette を追加する**

`vignettes/wPGSAR.Rmd` を作る。ChIP-Atlas からの取得を含めるとビルドに 1.2 GB を要するため、同梱データだけで完結させる。

````markdown
---
title: "Inferring transcription factor activity with wPGSAR"
output: BiocStyle::html_document
vignette: >
  %\VignetteIndexEntry{Inferring transcription factor activity with wPGSAR}
  %\VignetteEngine{knitr::rmarkdown}
  %\VignetteEncoding{UTF-8}
---

```{r setup, include = FALSE}
knitr::opts_chunk$set(collapse = TRUE, comment = "#>")
```

# What wPGSA does

wPGSA infers the activity of transcription factors from a gene expression
matrix, by asking whether the genes a TF binds move differently from the rest
of the transcriptome. Each TF's targets are weighted by how often the binding
was actually observed across ChIP experiments, so a target seen in one
experiment out of twenty counts for less than one seen in every experiment.

# A worked example

```{r}
library("wPGSAR")
data(GSE143371_count)
data(GSE143371_group)
dim(GSE143371_count)
```

The network normally comes from ChIP-Atlas via `retrieveNetworkData()`. That
downloads about 1.2 GB, so this vignette builds a small one by hand to keep
the example self-contained.

```{r}
network_data <- data.frame(
  TF_name  = rep(c("TF_A", "TF_B"), each = 3),
  GeneName = c("TSPAN6", "TNMD", "DPM1", "TSPAN6", "SCYL3", "DPM1"),
  weight   = c(1, 0.5, 0.25, 1, 1, 0.75))
res <- wPGSA(network_data, GSE143371_count)
res$tstat
```

Supplying group labels adds a test between groups.

```{r}
res2 <- wPGSA(network_data, GSE143371_count, GSE143371_group)
res2$pval
```

# Session information

```{r}
sessionInfo()
```
````

`DESCRIPTION` の `Suggests` に `BiocStyle` を追加する。

- [ ] **Step 9: NEWS の重複を削除する**

`inst/NEWS` にある2つ目の `VERSION 0.99.1` の項を削除する。

- [ ] **Step 10: R CMD check が通ることを確認する**

```bash
cd ~/repos/wPGSAR
docker run --rm -v "$PWD:/work" -w /work wpgsar-dev \
  bash -c "R CMD build . && R CMD check --no-manual wPGSAR_*.tar.gz" 2>&1 | tail -20
```

期待: Task 1 のベースラインに出ていた vignette 関連の指摘が消える。残った指摘は `.dev/baseline-check.log` と突き合わせ、この PR で増えたものが無いことを確認する。

- [ ] **Step 11: roxygen を再生成してコミット、push する**

```bash
cd ~/repos/wPGSAR
docker run --rm -v "$PWD:/work" -w /work wpgsar-dev R -q -e 'roxygen2::roxygenise(".")'
git add R man vignettes DESCRIPTION inst/NEWS tests
git commit -m "Name the assembly the URLs serve, and enable mm10

assembly = \"hg19\" fetched wpgsa_GRN.hg38.5.tsv. The data was right and the
label was wrong, so hg19 stays accepted with a deprecation warning rather
than breaking callers.

mm10 was refused as unavailable, but wpgsa_GRN.mm10.5.tsv (1.01 GB) and
wpgsa_hash.mm10.5.tsv are both served today.

Also: the group-length check said nrow while testing ncol, the Rd gave
test.method's default as \"t\" where the code uses \"lm\", NEWS carried
0.99.1 twice, and DESCRIPTION declared a VignetteBuilder with no vignettes
directory, which Bioconductor requires and R CMD check flags."
git push -u origin fix-assembly-names-and-package-metadata
```

- [ ] **Step 12: ユーザーの合図を待ってから PR を出す**

---

### Task 6: PR2-a — ネットワークを factor で持ち、整数コードで索引付けする

**Files:**
- Modify: `R/retrieveNetworkData.R`
- Modify: `R/wPGSA.R`（`.filterwPGSA`, `.sparseMatrix`）
- Modify: `tests/testthat/test-wPGSA.R`
- Modify: `DESCRIPTION`

**Interfaces:**
- Consumes: Task 5 の `.networkURLs(assembly)`
- Produces: `.levelIndex(x, table)` — factor でも character でも `match` 相当の整数を返す。Task 10 が使う
- Produces: `.experimentLabels(srx_levels, hash)`, `.networkByExperiment(grn, hash)` — Task 9 が使う

- [ ] **Step 1: ブランチを切る**

```bash
cd ~/repos/wPGSAR && git checkout main && git pull --ff-only
git checkout -b index-the-network-by-code-not-by-string
```

- [ ] **Step 2: 数値が変わらないことを主張する失敗するテストを書く**

`tests/testthat/test-wPGSA.R` に追加する。character の `network_data` を渡しても factor の `network_data` を渡しても同じ結果になる、というのがこの PR の中心的な主張である。

```r
test_that("a factor network gives the same result as a character network", {
  chr <- dummy_network_data
  fac <- transform(dummy_network_data,
                   TF_name  = factor(TF_name),
                   GeneName = factor(GeneName))

  res_chr <- wPGSA(chr, dummy_GSE143371_count)
  res_fac <- wPGSA(fac, dummy_GSE143371_count)

  expect_equal(rownames(res_fac$tstat), rownames(res_chr$tstat))
  expect_equal(as.matrix(res_fac$tstat), as.matrix(res_chr$tstat),
               tolerance = 1e-10)
})

test_that("TFs whose targets are all unmeasured are left out of the result", {
  net <- rbind(
    dummy_network_data,
    data.frame(TF_name = "TF_WITH_NO_MEASURED_TARGETS",
               GeneName = c("NOT_MEASURED_1", "NOT_MEASURED_2"),
               weight = 1))
  res <- wPGSA(net, dummy_GSE143371_count)
  expect_false("TF_WITH_NO_MEASURED_TARGETS" %in% rownames(res$tstat))
})

test_that("the order of TFs follows first appearance in the network", {
  net <- data.frame(
    TF_name  = c("Z_TF", "A_TF", "Z_TF"),
    GeneName = c("FRG2C", "FRG2C", "DUX4"),
    weight   = 1)
  res <- wPGSA(net, dummy_GSE143371_count)
  expect_equal(rownames(res$tstat), c("Z_TF", "A_TF"))
})
```

3番目は、この書き換えで壊しやすい性質を先に固定するためのものである。水準順に並べ替えると `A_TF`, `Z_TF` になってしまい、行位置で結果を参照している利用者が黙って壊れる。

- [ ] **Step 3: テストを実行して、どれが落ちるかを確かめる**

```bash
cd ~/repos/wPGSAR
docker run --rm -e CI=true -v "$PWD:/work" -w /work wpgsar-dev \
  R -q -e 'devtools::load_all("."); testthat::test_local()' 2>&1 | tail -20
```

期待: 1番目が落ちる。現行の `.filterwPGSA` は factor に `%in%` を掛けて character に変換するため動きはするが、`unique()` が factor を返し `dimnames` が水準順になるため rownames が一致しない。2番目と3番目は現行でも通るはずで、通るなら「保持すべき挙動」を正しく写し取れている証拠になる。

3番目が現行で落ちる場合は、現行がすでに水準順であるということなので、テストの期待値を現行に合わせてから先へ進む。**推測で書き換えないこと。**

- [ ] **Step 4: factor 対応の索引付けヘルパーを実装する**

`R/wPGSA.R` に追加する。

```r
# match() against a factor coerces it to character, which materialises one
# string per row -- 57 million of them for a genome-wide ChIP-Atlas network.
# Matching the levels instead costs one lookup per distinct name.
.levelIndex <- function(x, table){
	if(is.factor(x)){
		match(levels(x), table)[as.integer(x)]
	}else{
		match(x, table)
	}
}

.firstAppearance <- function(x){
	if(is.factor(x)){
		codes <- as.integer(x)
		levels(x)[codes[!duplicated(codes)]]
	}else{
		unique(x)
	}
}
```

- [ ] **Step 5: `.filterwPGSA` と `.sparseMatrix` を書き換える**

```r
.filterwPGSA <- function(network_data, expression_data, commonGeneName){
	keep <- !is.na(.levelIndex(network_data$GeneName, commonGeneName))
	network_data <- network_data[keep, , drop = FALSE]
	TFs <- .firstAppearance(network_data$TF_name)
	expression_data <- expression_data[commonGeneName, , drop = FALSE]
	list(network_data=network_data,
		TFs=TFs,
		expression_data=expression_data)
}

.sparseMatrix <- function(network_data, TFs, commonGeneName){
	sparseMatrix(
		i = .levelIndex(network_data$TF_name, TFs),
		j = .levelIndex(network_data$GeneName, commonGeneName),
		x = network_data$weight,
		dims = c(length(TFs), length(commonGeneName)),
		dimnames = list(TFs, commonGeneName))
}
```

`data.table` を使った旧 `.sparseMatrix` は不要になる。`R/wPGSA.R` の `@importFrom data.table as.data.table` を外す。

- [ ] **Step 6: `.checkwPGSA` の `unique()` も factor 対応にする**

```r
	commonGeneName <- intersect(
		.firstAppearance(network_data$GeneName),
		rownames(expression_data))
```

`unique(network_data$GeneName)` は factor に対して factor を返し、`intersect` が character に変換する。ここでも 5,758万要素の変換が起きる。

- [ ] **Step 7: テストが通ることを確認する**

```bash
cd ~/repos/wPGSAR
docker run --rm -e CI=true -v "$PWD:/work" -w /work wpgsar-dev \
  R -q -e 'devtools::load_all("."); testthat::test_local()' 2>&1 | tail -15
```

期待: すべて PASS。

- [ ] **Step 8: `retrieveNetworkData` を factor で読むようにする**

`R/retrieveNetworkData.R` の読み込みと結合を置き換える。

```r
	# Read the names as factors and label the experiments once per SRX, not
	# once per binding event: the mm10 table has 19,509 experiments and
	# 57,585,550 rows.
	grn <- data.table::fread(outfile1, sep="\t", header=FALSE,
		col.names=c("SRX_id", "GeneName"), stringsAsFactors=TRUE)
	hash <- data.table::fread(outfile2, sep="\t", header=FALSE,
		col.names=c("SRX_id", "TF", "celltype1", "celltype2"))

	cat("(3/3) Two files are being merged...\n")
	.networkByExperiment(grn, hash)
```

および

```r
.experimentLabels <- function(srx_levels, hash){
	i <- match(srx_levels, hash$SRX_id)
	paste(hash$TF[i], hash$celltype1[i], hash$celltype2[i], srx_levels, sep="_")
}

.networkByExperiment <- function(grn, hash){
	TF_name <- grn$SRX_id
	levels(TF_name) <- .experimentLabels(levels(TF_name), hash)
	data.frame(
		TF_name  = TF_name,
		GeneName = grn$GeneName,
		weight   = 1)
}
```

`dplyr::left_join` と `utils::read.delim` を使わなくなるため、`DESCRIPTION` の `Imports` から `dplyr` を外し、`R/retrieveNetworkData.R` の `@importFrom dplyr left_join` と `@importFrom utils read.delim` を削除する。`data.table` はすでに `Imports` にある。

- [ ] **Step 9: 疎行列の背景分散を直す**

`R/wPGSA.R` に追加し、`wPGSA()` の `global_var <- apply(expression_data, 2, var)` を差し替える。

```r
# apply() calls as.matrix() on an S4 object, so passing a dgCMatrix here
# densifies the whole expression matrix -- the one thing sparse input is
# meant to avoid. The dense branch is left exactly as it was.
.global_var <- function(expression_data){
	if("dgCMatrix" %in% is(expression_data)){
		n <- nrow(expression_data)
		m <- Matrix::colMeans(expression_data)
		(Matrix::colSums(expression_data^2) - n * m^2) / (n - 1)
	}else{
		apply(expression_data, 2, var)
	}
}
```

`@importFrom Matrix colSums` を追加する。

- [ ] **Step 10: 密と疎で一致することを確認する**

Task 4 の Step 3 で書いた「疎行列でも同じ数になる」テストがこれを検査している。

```bash
cd ~/repos/wPGSAR
docker run --rm -e CI=true -v "$PWD:/work" -w /work wpgsar-dev \
  R -q -e 'devtools::load_all("."); testthat::test_local()' 2>&1 | tail -15
```

期待: すべて PASS。

- [ ] **Step 11: 実データで数値が変わらないことと、性能を測る**

```bash
cd ~/repos/wPGSAR
cat > .dev/compare_perf.R <<'EOF'
devtools::load_all(".")
suppressPackageStartupMessages({library(data.table)})
grn <- fread("/data/wpgsa_GRN.mm10.5.tsv", sep="\t", header=FALSE,
             col.names=c("SRX_id","GeneName"), stringsAsFactors=TRUE)
hash <- fread("/data/wpgsa_hash.mm10.5.tsv", sep="\t", header=FALSE,
              col.names=c("SRX_id","TF","celltype1","celltype2"))
t0 <- proc.time()
network_data <- wPGSAR:::.networkByExperiment(grn, hash)
expr <- as.matrix(read.delim("/data/logfc.txt", row.names=1, check.names=FALSE))
res <- wPGSA(network_data, expr)
cat("elapsed:", (proc.time()-t0)[["elapsed"]], "s  tstat:", dim(res$tstat), "\n")
cat("R max used MB:", sum(gc(FALSE)[, "max used"] * c(8,8))/1e6, "\n")
saveRDS(as.matrix(res$tstat), "/data/tstat_after.rds")
EOF
docker run --rm -v "$PWD:/work" -v "$HOME/data/chip-atlas:/data" -w /work wpgsar-dev \
  bash -c "/usr/bin/time -v Rscript .dev/compare_perf.R" 2>&1 | \
  grep -E "elapsed|max used|tstat|Maximum resident"
```

期待: Task 1 の 27.8 秒 / 7.16 GB に対して、10 秒未満 / 5 GB 前後。手元の測定では 8.4 秒 / 4.93 GB だった。

- [ ] **Step 12: 変更前の出力と突き合わせる**

Task 1 の Step 5 で保存した `tstat_before.rds` と比較する。

```bash
docker run --rm -v "$HOME/data/chip-atlas:/data" wpgsar-dev Rscript -e '
  a <- readRDS("/data/tstat_before.rds"); b <- readRDS("/data/tstat_after.rds")
  tf <- intersect(rownames(a), rownames(b))
  cat("shared rows:", length(tf), "of", nrow(a), "and", nrow(b), "\n")
  cat("max abs difference:", max(abs(a[tf,] - b[tf,]), na.rm=TRUE), "\n")'
```

期待: 行数が一致し、最大絶対差が 1e-10 未満。手元の試作では 1.4e-13 だった。

**行数が一致しない場合は先へ進まないこと。** それは「標的遺伝子が発現データに無い TF を落とす」挙動が壊れたということであり、Step 2 の2番目のテストが本来それを捕まえるはずである。

- [ ] **Step 13: NEWS とバージョンを更新してコミット、push する**

```bash
cd ~/repos/wPGSAR
git add R DESCRIPTION inst/NEWS tests man
git commit -m "Index the network by factor code instead of by string

Every lookup went through the names. %in% and match() coerce a factor to
character, so filtering a genome-wide network built one string per row --
57,585,550 of them for ChIP-Atlas mm10 -- and the per-experiment label was
pasted once per binding event rather than once per experiment.

Reading the two name columns as factors and matching on the levels drops the
mm10 run from 27.8 s and 7.16 GB peak RSS to 8.4 s and 4.93 GB. t-statistics
agree with the previous implementation to 1.4e-13.

The background variance also went through apply(), which calls as.matrix()
on an S4 object and so densified any sparse expression matrix handed to it.
The dense branch is unchanged; sparse input now stays sparse."
git push -u origin index-the-network-by-code-not-by-string
```

- [ ] **Step 14: ユーザーの合図を待ってから PR を出す**

---

### Task 7: 相互参照フィクスチャを作る

PR3 のゴールデンテストが要求する材料を、wpgsa.org 側で生成する。上流には成果物だけを持ち込む。

**Files:**
- Create: `~/repos/wpgsa.org/script/build-legacy-fixture.sh`
- Create: `~/repos/wPGSAR/inst/extdata/legacy/network.tsv`
- Create: `~/repos/wPGSAR/inst/extdata/legacy/logfc.tsv`
- Create: `~/repos/wPGSAR/inst/extdata/legacy/t_score.tsv`
- Create: `~/repos/wPGSAR/inst/extdata/legacy/p_value.tsv`
- Create: `~/repos/wPGSAR/inst/extdata/legacy/README.md`

**Interfaces:**
- Produces: `inst/extdata/legacy/` 以下の4ファイル。Task 8 のゴールデンテストが読む

- [ ] **Step 1: 生成スクリプトを書く**

`~/repos/wpgsa.org/script/build-legacy-fixture.sh`:

```bash
#!/usr/bin/env bash
# Produces the reference case that wPGSAR's golden test checks itself
# against: a small slice of the 2016 mouse network and the published sample
# input, run through the container the site used from 2016 to 2026.
#
# Usage: script/build-legacy-fixture.sh <output-dir>
set -euo pipefail

OUT="${1:?usage: build-legacy-fixture.sh <output-dir>}"
APP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NETWORK="$APP_ROOT/data/merged_mouse_v7_160212.network"
IMAGE="inutano/wpgsa:0.5.2"
N_TF=20
N_GENE=500

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Take the first N_TF transcription factors in file order, so the slice is
# reproducible without depending on a random seed.
head -1 "$NETWORK" > "$work/network.tsv"
awk -F'\t' -v n="$N_TF" 'NR>1 {
  if (!($1 in seen)) { seen[$1]=1; k++ }
  if (k > n) exit
  print
}' "$NETWORK" >> "$work/network.tsv"

curl -sL -o "$work/full_logfc.txt" \
  https://raw.githubusercontent.com/eiryo-kawakami/wPGSA/master/sample_logFC_file/GSE63786_Kawasaki_Influenza_Virus_logFC.txt

# Keep only genes the sliced network actually targets, so the fixture
# exercises the intersection rather than a mostly-empty matrix.
cut -f3 "$work/network.tsv" | tail -n +2 | sort -u > "$work/targets.txt"
head -1 "$work/full_logfc.txt" > "$work/logfc.txt"
awk -F'\t' -v n="$N_GENE" 'NR==FNR { t[$1]=1; next }
  FNR>1 && ($1 in t) && c<n { print; c++ }' \
  "$work/targets.txt" "$work/full_logfc.txt" >> "$work/logfc.txt"

docker run --rm -i --platform linux/amd64 -v "$work:/data" "$IMAGE" \
  wpgsa --logfc-file /data/logfc.txt --network-file /data/network.tsv 2>/dev/null

mkdir -p "$OUT"
cp "$work/network.tsv" "$OUT/network.tsv"
cp "$work/logfc.txt" "$OUT/logfc.tsv"
cp "$work/logfc_TF_wPGSA_t_score.txt" "$OUT/t_score.tsv"
cp "$work/logfc_TF_wPGSA_p_value.txt" "$OUT/p_value.tsv"

echo "wrote fixture to $OUT"
wc -l "$OUT"/*.tsv
```

- [ ] **Step 2: 実行してフィクスチャを作る**

```bash
cd ~/repos/wpgsa.org
chmod +x script/build-legacy-fixture.sh
./script/build-legacy-fixture.sh ~/repos/wPGSAR/inst/extdata/legacy
```

期待: 4ファイルが書かれ、`t_score.tsv` が 21 行（ヘッダ + 20 TF）前後になる。1〜2分かかる。

- [ ] **Step 3: 中身が妥当であることを確かめる**

```bash
head -2 ~/repos/wPGSAR/inst/extdata/legacy/t_score.tsv | cut -c1-120
awk -F'\t' 'NR>1 && ($4 < 0 || $4 > 1) { bad++ } END { print "p out of [0,1]:", bad+0 }' \
  ~/repos/wPGSAR/inst/extdata/legacy/p_value.tsv
```

期待: ヘッダが `TF Number_of_ChIPexp t_score_mean` で始まり、p 値がすべて 0〜1 に収まる。

- [ ] **Step 4: 由来を書き残す**

`~/repos/wPGSAR/inst/extdata/legacy/README.md`:

```markdown
# Reference output from the 2016 implementation

These four files pin wPGSAR to the implementation the method was published
with. `t_score.tsv` and `p_value.tsv` were produced by running
`network.tsv` and `logfc.tsv` through `inutano/wpgsa:0.5.2`, the container
wpgsa.org served from 2016 to 2026, which packages wPGSA.py 1.1.0 from
`eiryo-kawakami/wPGSA`.

- `network.tsv` — the first 20 transcription factors of
  `merged_mouse_v7_160212.network`, in file order
- `logfc.tsv` — up to 500 genes of GSE63786 that the sliced network targets
- `t_score.tsv`, `p_value.tsv` — what the 2016 container produced from them

Regenerate with `script/build-legacy-fixture.sh` in the wpgsa.org
repository. The slice is deterministic: no sampling, no seed.

The legacy p-value is `scipy.stats.t.sf(abs(t_score), df)`, which is exactly
half of a two-sided p-value, not `alternative = "greater"`.
```

- [ ] **Step 5: wpgsa.org 側のスクリプトをコミットする**

```bash
cd ~/repos/wpgsa.org
git checkout -b legacy-fixture-generator
git add script/build-legacy-fixture.sh
git commit -m "Add a generator for the wPGSAR reference fixture

The upstream package needs a case it can check itself against: input and
output from the implementation the method was published with. This produces
one from a deterministic slice of the reference network and the published
sample input, run through the 2016 container."
git push -u origin legacy-fixture-generator
```

---

### Task 8: PR3 — `n_eff` の継ぎ目とサンプルごとの p 値・q 値

**Files:**
- Modify: `R/wPGSA.R`
- Modify: `tests/testthat/test-wPGSA.R`
- Create: `tests/testthat/test-legacy-reference.R`
- Create: `inst/extdata/legacy/`（Task 7 の成果物）
- Modify: `man/wPGSA.Rd`（roxygen 再生成）

**Interfaces:**
- Consumes: Task 6 の `.levelIndex`, `.firstAppearance`
- Consumes: Task 7 の `inst/extdata/legacy/`
- Produces: `.effectiveN(network_data, network_sparse, TFs, se.denom)`, `.tstat_df(global_var, target_var, n_eff)`, `.tstat_pval(tstat, df, alternative)`。Task 10 が `se.denom` の既定を変える

- [ ] **Step 1: ブランチを切る**

```bash
cd ~/repos/wPGSAR && git checkout main && git pull --ff-only
git checkout -b per-sample-p-values
```

- [ ] **Step 2: ゴールデンテストを書く**

`tests/testthat/test-legacy-reference.R`:

```r
# Pins wPGSAR to the implementation wPGSA was published with. See
# inst/extdata/legacy/README.md for how the fixture was produced.
legacy_path <- function(name) {
  system.file("extdata", "legacy", name, package = "wPGSAR")
}

read_legacy_result <- function(name) {
  df <- read.delim(legacy_path(name), row.names = 1, check.names = FALSE)
  as.matrix(df[, -c(1, 2)])   # drop Number_of_ChIPexp and the mean column
}

legacy_inputs <- function() {
  net <- read.delim(legacy_path("network.tsv"), check.names = FALSE)
  colnames(net) <- c("TF_Uniprot", "TF_egSym", "TargetSym",
                     "positive", "experiment")
  list(
    network = data.frame(
      TF_name  = net$TF_Uniprot,
      GeneName = net$TargetSym,
      weight   = net$positive / net$experiment),
    expression = as.matrix(read.delim(legacy_path("logfc.tsv"),
                                      row.names = 1, check.names = FALSE)))
}

test_that("t-statistics match the 2016 implementation", {
  inp <- legacy_inputs()
  res <- wPGSA(inp$network, inp$expression, se.denom = "targets_all")
  want <- read_legacy_result("t_score.tsv")

  tf <- rownames(want)
  expect_setequal(rownames(res$tstat), tf)
  expect_equal(as.matrix(res$tstat)[tf, colnames(want)], want,
               tolerance = 1e-10)
})

test_that("half the two-sided p-value matches the 2016 implementation", {
  inp <- legacy_inputs()
  res <- wPGSA(inp$network, inp$expression, se.denom = "targets_all",
               alternative = "two.sided")
  want <- read_legacy_result("p_value.tsv")

  tf <- rownames(want)
  expect_equal(res$tstat_pval[tf, colnames(want)] / 2, want,
               tolerance = 1e-10)
})
```

- [ ] **Step 3: テストが失敗することを確認する**

```bash
cd ~/repos/wPGSAR
docker run --rm -e CI=true -v "$PWD:/work" -w /work wpgsar-dev \
  R -q -e 'devtools::load_all("."); testthat::test_local()' 2>&1 | tail -20
```

期待: `unused argument (se.denom = "targets_all")` で落ちる。

- [ ] **Step 4: `n_eff` を実装する**

`R/wPGSA.R` に追加する。

```r
# The quantity the standard error and the degrees of freedom divide by.
#
#  weights      the sum of weights over the genes shared with the expression
#               matrix. What this package has always used.
#  targets      the number of target genes among those shared genes.
#  targets_all  the number of target genes in the whole network, including
#               genes the expression matrix never measured. What the 2016
#               implementation uses, which is why it needs the unfiltered
#               network rather than the sparse matrix.
#
# See https://github.com/chiba-ai-med/wPGSAR/issues/<N> for which of these
# the published definition intends.
.effectiveN <- function(network_data, network_sparse, TFs, se.denom){
	switch(se.denom,
		weights = Matrix::rowSums(network_sparse),
		targets = Matrix::rowSums(network_sparse != 0),
		targets_all = {
			i <- .levelIndex(network_data$TF_name, TFs)
			as.numeric(tabulate(i, nbins = length(TFs)))
		})
}
```

`targets_all` に渡す `network_data` は絞り込み前のものである点に注意する。

- [ ] **Step 5: 自由度と p 値を実装する**

```r
.tstat_df <- function(global_var, target_var, n_eff){
	vb <- Matrix::t(matrix(global_var, ncol(target_var), nrow(target_var)))
	num <- (vb + target_var)^2
	den <- vb^2 + target_var^2
	as.matrix((n_eff - 1) * num / den)
}

.tstat_pval <- function(tstat, df, alternative){
	switch(alternative,
		two.sided = 2 * stats::pt(-abs(tstat), df),
		greater   = stats::pt(tstat, df, lower.tail = FALSE),
		less      = stats::pt(tstat, df))
}

.tstat_fdr <- function(pval){
	apply(pval, 2, p.adjust, method = "BH")
}
```

`@importFrom stats pt` を追加する。

- [ ] **Step 6: `wPGSA()` の引数と本体を配線する**

```r
wPGSA <- function(network_data, expression_data, group=NULL,
	test.method=c("lm", "wilcox"),
	alternative=c("two.sided", "greater", "less"),
	se.denom=c("weights", "targets", "targets_all")){
	test.method <- match.arg(test.method)
	alternative <- match.arg(alternative)
	se.denom <- match.arg(se.denom)
	...
	network_sparse <- .sparseMatrix(
		res.filter$network_data, res.filter$TFs, commonGeneName)
	n_eff <- .effectiveN(network_data, network_sparse, res.filter$TFs, se.denom)
	total_sum <- rowSums(network_sparse)
	target_mean <- .targetMean(network_sparse, res.filter$expression_data, total_sum)
	target_var <- .targetVar(network_sparse, res.filter$expression_data,
		total_sum, target_mean)
	tstat_se <- .tstat_se(global_var, target_var, n_eff)
	tstat <- .tstat(global_mean, target_mean, tstat_se)
	tstat_df <- .tstat_df(global_var, target_var, n_eff)
	tstat_pval <- .tstat_pval(as.matrix(tstat), tstat_df, alternative)
	tstat_fdr <- .tstat_fdr(tstat_pval)
	...
	list(tstat=tstat, tstat_se=tstat_se,
		tstat_pval=tstat_pval, tstat_fdr=tstat_fdr,
		group_mean=..., ...)
}
```

**重要:** 重み付き平均と重み付き分散は `total_sum`（重み合計）で割り続ける。これは論文でも `Σ(Ep)/Σp` であり議論の余地がない。`n_eff` が入るのは標準誤差と自由度だけである。`.tstat_se` の引数名を `total_sum` から `n_eff` に変える。

`se.denom` の既定は `"weights"` であり、現行の振る舞いは変わらない。

- [ ] **Step 7: 戻り値が9要素になったことを既存テストに反映する**

Task 4 で書いた `expect_equal(length(res), 7)` を 9 に更新する。

- [ ] **Step 8: テストが通ることを確認する**

```bash
cd ~/repos/wPGSAR
docker run --rm -e CI=true -v "$PWD:/work" -w /work wpgsar-dev \
  R -q -e 'devtools::load_all("."); testthat::test_local()' 2>&1 | tail -20
```

期待: ゴールデンテスト2件を含め、すべて PASS。

**落ちる場合**、まず `se.denom = "targets_all"` の数え方を疑う。レガシーは `positive[TF]` の要素数、つまりネットワーク上の**相異なる標的遺伝子数**を数えており、行数ではない。同じ TF-遺伝子の組が2行ある場合に食い違う。フィクスチャに重複があるかを確認する。

- [ ] **Step 9: 既定の振る舞いが変わっていないことを確認する**

```bash
cd ~/repos/wPGSAR
docker run --rm -v "$PWD:/work" -v "$HOME/data/chip-atlas:/data" -w /work wpgsar-dev \
  Rscript -e 'devtools::load_all("."); library(data.table)
    grn <- fread("/data/wpgsa_GRN.mm10.5.tsv", sep="\t", header=FALSE,
                 col.names=c("SRX_id","GeneName"), stringsAsFactors=TRUE)
    hash <- fread("/data/wpgsa_hash.mm10.5.tsv", sep="\t", header=FALSE,
                  col.names=c("SRX_id","TF","celltype1","celltype2"))
    nd <- wPGSAR:::.networkByExperiment(grn, hash)
    expr <- as.matrix(read.delim("/data/logfc.txt", row.names=1, check.names=FALSE))
    a <- readRDS("/data/tstat_after.rds")
    b <- as.matrix(wPGSA(nd, expr)$tstat)
    cat("max abs difference:", max(abs(a - b), na.rm=TRUE), "\n")'
```

期待: 0、または 1e-12 未満。

- [ ] **Step 10: roxygen を再生成し、NEWS とバージョンを更新してコミット、push する**

```bash
cd ~/repos/wPGSAR
docker run --rm -v "$PWD:/work" -w /work wpgsar-dev R -q -e 'roxygen2::roxygenise(".")'
git add R man tests inst DESCRIPTION
git commit -m "Return a p-value and an FDR for each sample

wPGSA() gave a t-statistic per TF per sample but no way to say which of them
mattered; pval and fdr describe the test between groups, which is a
different question and is only computed when group labels are supplied.

tstat_pval and tstat_fdr come from the Welch-Satterthwaite degrees of
freedom, two-sided by default because that is how the paper states the null
hypothesis. alternative= selects a one-sided test.

The standard error and the degrees of freedom now divide by one named
quantity, se.denom, defaulting to the sum of weights this package has always
used. The 2016 implementation divides by the target-gene count instead --
see #<N> -- and having the choice in one place is what lets the new golden
test reproduce its output exactly."
git push -u origin per-sample-p-values
```

- [ ] **Step 11: ユーザーの合図を待ってから PR を出す**

---

### Task 9: PR4 — TF 単位への集約と k/n 重み

**Files:**
- Modify: `R/retrieveNetworkData.R`
- Modify: `tests/testthat/test-retrieveNetworkData.R`
- Modify: `tests/testthat/helper-wPGSA.R`
- Modify: `man/retrieveNetworkData.Rd`（roxygen 再生成）

**Interfaces:**
- Consumes: Task 6 の `.experimentLabels`, `.networkByExperiment`
- Produces: `.networkByTF(grn, hash)`, `retrieveNetworkData(assembly, resolution)`

- [ ] **Step 1: ブランチを切る**

```bash
cd ~/repos/wPGSAR && git checkout main && git pull --ff-only
git checkout -b weight-targets-by-binding-frequency
```

- [ ] **Step 2: 集約について、失敗するテストを書く**

`tests/testthat/test-retrieveNetworkData.R` に追加する。手で数えられる大きさにする。

```r
tiny_inputs <- function() {
  # TF_A ran in 3 experiments, TF_B in 1.
  hash <- data.frame(
    SRX_id    = c("SRX1", "SRX2", "SRX3", "SRX4"),
    TF        = c("TF_A", "TF_A", "TF_A", "TF_B"),
    celltype1 = "Blood",
    celltype2 = "K562")
  # GENE1 was bound in 2 of TF_A's 3 experiments, GENE2 in 1 of 3.
  grn <- data.frame(
    SRX_id   = factor(c("SRX1", "SRX2", "SRX1", "SRX4")),
    GeneName = factor(c("GENE1", "GENE1", "GENE2", "GENE1")))
  list(grn = grn, hash = hash)
}

test_that("TF resolution weights a target by the fraction of experiments binding it", {
  inp <- tiny_inputs()
  net <- wPGSAR:::.networkByTF(inp$grn, inp$hash)

  expect_setequal(as.character(net$TF_name), c("TF_A", "TF_B"))
  w <- function(tf, gene) {
    net$weight[as.character(net$TF_name) == tf &
               as.character(net$GeneName) == gene]
  }
  expect_equal(w("TF_A", "GENE1"), 2 / 3)
  expect_equal(w("TF_A", "GENE2"), 1 / 3)
  expect_equal(w("TF_B", "GENE1"), 1)
})

test_that("every aggregated weight is a probability", {
  inp <- tiny_inputs()
  net <- wPGSAR:::.networkByTF(inp$grn, inp$hash)
  expect_true(all(net$weight > 0))
  expect_true(all(net$weight <= 1))
})

test_that("experiment resolution stays the default", {
  expect_equal(eval(formals(retrieveNetworkData)$resolution)[1], "experiment")
})
```

- [ ] **Step 3: テストが失敗することを確認する**

```bash
cd ~/repos/wPGSAR
docker run --rm -e CI=true -v "$PWD:/work" -w /work wpgsar-dev \
  R -q -e 'devtools::load_all("."); testthat::test_local()' 2>&1 | tail -20
```

期待: `.networkByTF` が存在せず3件とも落ちる。

- [ ] **Step 4: `.networkByTF` を実装する**

`R/retrieveNetworkData.R` に追加する。

```r
# The paper weights a target gene by the probability that the TF regulates
# it, estimated as k/n from k binding events in n ChIP experiments. ChIP-Atlas
# distributes the individual events, so k and n are both recoverable -- which
# is how the network distributed with the 2016 implementation was built.
.networkByTF <- function(grn, hash){
	tf_of_srx <- factor(hash$TF[match(levels(grn$SRX_id), hash$SRX_id)])
	if(anyNA(tf_of_srx)){
		warning(sum(is.na(tf_of_srx)),
			" experiments have no entry in the metadata table and are dropped.")
	}
	n_per_tf <- as.integer(table(tf_of_srx))

	tf   <- as.integer(tf_of_srx)[as.integer(grn$SRX_id)]
	gene <- as.integer(grn$GeneName)
	keep <- !is.na(tf)

	dt <- data.table::data.table(tf = tf[keep], gene = gene[keep])
	agg <- dt[, list(k = .N), by = c("tf", "gene")]

	data.frame(
		TF_name  = factor(levels(tf_of_srx)[agg$tf], levels = levels(tf_of_srx)),
		GeneName = factor(levels(grn$GeneName)[agg$gene],
			levels = levels(grn$GeneName)),
		weight   = agg$k / n_per_tf[agg$tf])
}
```

- [ ] **Step 5: `retrieveNetworkData` に `resolution` を足す**

```r
retrieveNetworkData <- function(assembly=c("hg38", "mm10"),
	resolution=c("experiment", "TF"),
	out.dir=tempdir()){
	...
	resolution <- match.arg(resolution)
	...
	cat("(3/3) Two files are being merged...\n")
	if(resolution == "experiment"){
		.networkByExperiment(grn, hash)
	}else{
		.networkByTF(grn, hash)
	}
}
```

roxygen に `@param resolution` を追加する。

```r
#' @param resolution Whether to score each ChIP experiment separately
#'   ("experiment", the default, one row per SRX with weight 1) or to
#'   aggregate to the transcription factor ("TF", weighting each target by
#'   the fraction of that TF's experiments in which it was bound).
```

- [ ] **Step 6: テストが通ることを確認する**

```bash
cd ~/repos/wPGSAR
docker run --rm -e CI=true -v "$PWD:/work" -w /work wpgsar-dev \
  R -q -e 'devtools::load_all("."); testthat::test_local()' 2>&1 | tail -15
```

期待: すべて PASS。

- [ ] **Step 7: 実データで規模と不変量を確かめる**

```bash
cd ~/repos/wPGSAR
docker run --rm -v "$PWD:/work" -v "$HOME/data/chip-atlas:/data" -w /work wpgsar-dev \
  bash -c "/usr/bin/time -v Rscript -e '
    devtools::load_all(\".\"); library(data.table)
    grn <- fread(\"/data/wpgsa_GRN.mm10.5.tsv\", sep=\"\t\", header=FALSE,
                 col.names=c(\"SRX_id\",\"GeneName\"), stringsAsFactors=TRUE)
    hash <- fread(\"/data/wpgsa_hash.mm10.5.tsv\", sep=\"\t\", header=FALSE,
                  col.names=c(\"SRX_id\",\"TF\",\"celltype1\",\"celltype2\"))
    net <- wPGSAR:::.networkByTF(grn, hash)
    cat(\"rows:\", nrow(net), \" TFs:\", nlevels(droplevels(net\$TF_name)), \"\n\")
    cat(\"weight in (0,1]:\", all(net\$weight > 0 & net\$weight <= 1), \"\n\")
    cat(\"weight range:\", range(net\$weight), \"\n\")'" 2>&1 | \
  grep -E "rows:|weight|Maximum resident"
```

期待: 5,928,646 行、869 TF、重みはすべて 0 より大きく 1 以下、範囲は 0.0007〜1 前後。

- [ ] **Step 8: 2016年版ネットワークとの照合を PR 本文用に取る**

この数字は PR の説明に載せるためのもので、テストにはしない。手順は
`docs/superpowers/specs/2026-08-21-wpgsar-upstream-contribution-design.md` の
「PR4 実測値」に記録済みである。413/454 TF が残り、共有 175万ペアで
重みの相関が pearson 0.515 / spearman 0.536 になる。再測して値が大きく違う場合は
ChIP-Atlas 側が更新されたということなので、新しい値を使う。

- [ ] **Step 9: PR 本文を書く**

`--fill` ではコミットメッセージだけになる。この PR は、これがネットワーク更新の
妥当性を検証したものではないことを明示する必要がある。`.dev/pr4-body.md` に書く。

```markdown
(コミットメッセージの本文をここに再掲したうえで、末尾に以下を足す)

### What this does not establish

Switching a mouse analysis from the network shipped in 2016 to ChIP-Atlas
changes the answers substantially, and this pull request does not show that
the new answers are better. On GSE63786, over the 413 TFs the two networks
share, the t-statistics agree at Pearson 0.798 and a median Spearman of
0.535, with 82% sign agreement and only 15% overlap in each sample's top 20
by |t|.

That is a biological question about the reference data, not a claim about
this code, and it wants validation against experiments with known answers
before anyone treats the new network as a drop-in replacement. What is being
proposed here is the option, not a change of default: `resolution` stays at
`"experiment"`.
```

- [ ] **Step 10: roxygen を再生成し、NEWS とバージョンを更新してコミット、push する**

```bash
cd ~/repos/wPGSAR
docker run --rm -v "$PWD:/work" -w /work wpgsar-dev R -q -e 'roxygen2::roxygenise(".")'
git add R man tests DESCRIPTION inst/NEWS
git commit -m "Add TF-resolution networks weighted by binding frequency

retrieveNetworkData set every weight to 1 and scored each ChIP experiment
separately. With uniform weights the analysis is not weighted, and the
weighting is the method: the paper estimates the probability that a TF
regulates a gene as k/n from k binding events across n experiments.

ChIP-Atlas distributes the individual events, so k and n are both
recoverable. resolution=\"TF\" reconstructs them. On mm10 that turns
57,585,550 binding events into 5,928,646 TF-gene pairs across 869 TFs,
which is also a tenth of the rows.

Against the network shipped with the 2016 implementation, 413 of its 454
TFs are still present, and over the 1,752,252 shared TF-gene pairs the
weights correlate at 0.515 (Pearson). The estimates differ because they now
rest on far more experiments: the median TF went from 3 to 14.

The default stays \"experiment\", so existing results do not move."
git push -u origin weight-targets-by-binding-frequency
```

- [ ] **Step 11: ユーザーの合図を待ってから PR を出す**

```bash
gh pr create --repo chiba-ai-med/wPGSAR --base main \
  --title "Add TF-resolution networks weighted by binding frequency" \
  --body-file .dev/pr4-body.md
```

---

### Task 10: PR5 — 標準誤差の分母（issue #1 の結論待ち）

**Files:**
- Modify: `R/wPGSA.R`（`.effectiveN` の既定のみ）
- Modify: `tests/testthat/test-wPGSA.R`
- Modify: `inst/NEWS`

**Interfaces:**
- Consumes: Task 8 の `.effectiveN(network_data, network_sparse, TFs, se.denom)`

**このタスクは issue #1 に返答があるまで着手しないこと。** 返答の内容で3通りに分岐する。

- [ ] **Step 1: issue #1 の返答を確認する**

```bash
gh issue view <N> --repo chiba-ai-med/wPGSAR --comments
```

- [ ] **Step 2A: 分母が標的遺伝子数だと確定した場合**

`se.denom` の既定を `"targets_all"` に変える。

```r
	se.denom=c("targets_all", "targets", "weights")
```

数値が変わるため、次のテストを追加する。

```r
test_that("the default standard error now matches the published definition", {
  inp <- legacy_inputs()
  res <- wPGSA(inp$network, inp$expression)
  want <- read_legacy_result("t_score.tsv")
  tf <- rownames(want)
  expect_equal(as.matrix(res$tstat)[tf, colnames(want)], want,
               tolerance = 1e-10)
})
```

`test-legacy-reference.R` の既存2件から `se.denom = "targets_all"` を外し、
既定で通ることを確かめる。`inst/NEWS` に破壊的変更として明記し、
`DESCRIPTION` のバージョンを上げる。

- [ ] **Step 2B: 重み合計が正しいと確定した場合**

上流の変更は不要である。`se.denom` は `targets_all` を選べる形で残し、
2016年実装との照合に使えるようにする。
このタスクを閉じ、wpgsa.org 側の設計書に「レガシーの数値は再現しない」ことと
その理由を記録する。

- [ ] **Step 3C: 決着しなかった場合**

`se.denom` を引数として残したまま、既定を `"weights"` に据え置く。
`man/wPGSA.Rd` に3つの選択肢の意味と、どれを選ぶべきかの判断材料を書く。
issue へのリンクを Rd に残す。

- [ ] **Step 4: どの分岐でも、テストを実行して通ることを確認する**

```bash
cd ~/repos/wPGSAR
docker run --rm -e CI=true -v "$PWD:/work" -w /work wpgsar-dev \
  R -q -e 'devtools::load_all("."); testthat::test_local()' 2>&1 | tail -15
```

- [ ] **Step 5: 変更がある分岐ではコミットして push し、ユーザーの合図を待って PR を出す**

---

## 完了の定義

- [ ] issue #1 が立ち、返答が得られている
- [ ] PR0-a, PR0-b, PR1, PR2-a, PR3, PR4 が PR として出ている
- [ ] PR5 が issue #1 の結論に沿って処理されている（変更なしで閉じる場合も含む）
- [ ] `R CMD check` が変更前より指摘を増やしていない
- [ ] 相互参照フィクスチャによるゴールデンテストが通る
- [ ] mm10 全体での実行が、変更前と 1e-10 以内で一致する
