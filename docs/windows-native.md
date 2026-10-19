# Windows ネイティブで動かす（Docker・WSL なし）

2026-10-18〜19 に Windows 実機（下の想定機）で「動作確認の手順」の 1〜7 を流した。
結果は §6、つまずいた点は [設計書](python-new-loop-design.md) §1.1 に反映した。
OCR だけは Linux と完全には一致しない（Windows 版 tesseract のビルドの違い。§6 の 4）。
§6 の前半は、取り込みが複数のサービス（crow・queen・noir・violet・panther・cendrillon）に分かれていたころの結果。
いまは取り込みは navi、モデルは queen（以前の lavenza）が受け持つ（設計書 §3 の 10）。

基本の運用は Linux + Docker（[production.md](production.md)）。こちらは Windows で
Docker Desktop + WSL2 を使わずに、Python と Node を直接動かす方法。
Elasticsearch と nginx は自分でインストールして起動する。

## 前提

| 項目 | 内容 |
| --- | --- |
| 想定機 | Intel Core i5-9400F（6コア6スレッド）、メモリ 32 GB |
| 元データ | ネットワークドライブ上（UNC パスで指定）、約 700 件（2026-10 時点）。ホワイトリストを通って取り込まれるのは約 190 件 |
| 動かし方 | Windows にログオンしている間だけ（タスクスケジューラの「ログオン時」で起動） |

## 1. インストールするもの

| もの | 入手先・注意 |
| --- | --- |
| uv | `winget install astral-sh.uv`。Python は **3.14**（リポジトリの `.python-version`）。uv が自動で選ぶ |
| Node.js（LTS） | `winget install OpenJS.NodeJS.LTS` |
| tesseract | UB Mannheim 版（5.5.0 で確認）。インストール時に「Additional language data」で **Japanese** を選ぶ。PATH には入らないので、`.env` の `TESSERACT_CMD` で場所を指定する。学習データは §3 の手順で Linux と同じものに差し替える |
| Elasticsearch 9.x | zip 版を展開し、`bin\elasticsearch-plugin install analysis-icu` と `analysis-kuromoji` を入れる。ヒープは `config\jvm.options.d\heap.options` に `-Xms4g` / `-Xmx4g`。`config\elasticsearch.yml` は下記 |
| nginx | Windows 版（zip）。設定は `infra\nginx\nginx.windows.conf` を `<nginx>\conf\nginx.conf` にコピーする（上流をサービス名ではなく `127.0.0.1:<port>` で書いたもの） |

`elasticsearch.yml` には、Linux の compose と同じ設定を書く。何も書かずに起動すると、ES 9 は
HTTPS と自動生成のパスワードを有効にするため、`http://127.0.0.1:9200` からつながらない。

```yaml
discovery.type: single-node
xpack.security.enabled: false
network.host: 127.0.0.1      # 自分の機械からだけ
```

## 2. Windows の設定

- **Windows Defender のスキャン対象から、文書ストア（`DST_DIR`）を外す。** 小さいファイルを大量に書くので、
  外さないと遅くなり、rename・削除がスキャン中のロックで失敗することもある（§6 の 5 に前後の値）
- **長いパスを有効にする**（HTML のファイル名は全角で 80〜100 文字ある）。管理者の PowerShell で:

  ```powershell
  New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" -Name LongPathsEnabled -Value 1 -PropertyType DWORD -Force
  ```

- **WSL や Docker Desktop で phantom（compose）を動かしているなら止める。** 8080 などのポートを取り合い、
  nginx が `bind() ... failed (10013)` で起動しない（`wsl --terminate <ディストリビューション>`）

## 3. セットアップ

```powershell
git clone https://github.com/hyperion13th144m/phantom.git
cd phantom
uv sync --all-packages
cd services\fox;   npm ci; $env:FOX_BASE_PATH='/fox'; npm run build; Remove-Item Env:FOX_BASE_PATH; cd ..\..
cd services\joker; npm ci; npm run build; cd ..\..

copy .env.windows.sample .env                                    # 中身を自分の環境に合わせる
copy scripts\launcher\phantom-launcher.sample.toml phantom-launcher.toml
```

- **fox は `FOX_BASE_PATH=/fox` を付けてビルドする。** nginx が `/fox/` を fox に渡すので、付けないと
  fox のページがすべて 404 になる（Docker のイメージはビルド引数で同じ値を渡している）
- fox は事前に型定義の生成が要る（[development.md](development.md) の「fox の型定義を生成する」）。
  生成スクリプトは bash なので、Linux 側で生成したものをコピーするか、Git Bash で実行する
- 改行はリポジトリの `.gitattributes` で LF に固定してある。Git for Windows の既定（`core.autocrlf=true`）でも
  作業ツリーは LF になる

**OCR の学習データを Linux と同じにする。** UB Mannheim のインストーラーが入れる `jpn.traineddata`（約 14 MB）は、
Linux のイメージ（Debian の `tesseract-ocr-jpn 1:4.1.0-2` = tessdata_fast 4.1.0、約 2.4 MB）と別物で、
OCR の結果がかなり変わる。navi のイメージから取り出して置き、`.env` の `TESSDATA_PREFIX` で指す。
Docker が使える機械（WSL の中など）で:

```bash
docker run --rm -v "$PWD/tessdata:/out" --entrypoint sh ghcr.io/hyperion13th144m/phantom-navi:main \
  -c 'cp /usr/share/tesseract-ocr/5/tessdata/{jpn,eng,osd}.traineddata /out/'
```

sha256 は jpn `1f5de923…b91b4d`、eng `7d4322bd…7170b2`（2026-10-19 の `:main`）。

## 4. 起動・停止

```powershell
uv run phantom-launcher up --console     # Ctrl+C で全部止まる
uv run phantom-launcher status           # 別のコンソールから
uv run phantom-launcher down
```

ログは `var\log\launcher\<サービス>-YYYYMMDD.log`。

プロセスは 6 個（queen・mona・skull・navi・fox・joker）。
取り込みが複数のサービスに分かれていたころの `.env`・`phantom-launcher.toml` を使っている場合は、
`phantom-launcher.toml` をひな形からコピーし直し、`.env` の `LAVENZA_URL` / `LAVENZA_HOST` を
`QUEEN_URL=http://127.0.0.1:8001` / `QUEEN_HOST=127.0.0.1` に置き換える（消えたサービスの項目は残っていても害は無い）。

ログオン時に自動で起動するには、タスクスケジューラに次のタスクを作る
（詳しくは [phantom-launcher の README](../scripts/launcher/README.md)）。

- 全般: 「ユーザーがログオンしているときのみ実行する」（「最上位の特権で実行する」は不要）
- トリガー: ログオン時（自分のアカウント）
- 操作: プログラム `<リポジトリ>\.venv\Scripts\phantom-launcherw.exe`、引数 `up`、開始 `<リポジトリ>`。
  開始は引用符を付けずに書く。空だと `phantom-launcher.toml` と `.env` が見つからない
- 設定: 「タスクを停止するまでの時間」をオフにする（既定の 3 日のままだと launcher ごと止められる）

`phantom-launcherw.exe` は Python の gui-scripts なのでコンソール画面は出ない。Elasticsearch と nginx は
このタスクでは起動しないので、自動で起動したいなら別のタスクにする。
2026-10-19 に（取り込みが分かれていたころの 11 サービスで）、ログオン時の起動（全サービス running）と、その状態からの `down`（約 20 秒で停止）を確認した。

定期的に取り込むときも、同じくタスクスケジューラから navi の API を叩く（`curl.exe -X POST http://127.0.0.1:8005/api/runs`）。

## 5. 動作確認の手順

上から順に実機で確かめ、結果（かかった時間・エラー）を記録する。

1. **環境構築**: `uv sync --all-packages` が通るか
2. **単体テスト**: 全サービスで `uv run --package <svc> pytest services/<svc>/tests`（[development.md](development.md) のテスト節）
3. **小規模の E2E**: テストデータを UNC パスで `SRC_DIR` に指定し、navi の取り込みを最後まで流す → joker で検索 → fox で表示
4. **同一性**: 同じ入力から Linux（Docker）で作った文書ストアと突き合わせる

   ```powershell
   uv run python scripts\diff-store.py \\linux-host\share\data D:\phantom\data
   ```

   JSON（ベクトル以外）と OCR テキストは一致するはず。ベクトルはコサイン 0.999 以上を一致とみなす。
   比べる2つは、libefiling の版と `NOIR_EMBEDDING_MAX_SEQ_LENGTH` をそろえて作ること（§6 の 4）
5. **性能**: 実データ 25 文書の取り込みにかかった時間を測る。Defender の除外の前後で測る
6. **長いパス・HTML**: 元データの最長パスを測る。HTML を取り込み、ファイル名のバイト長の判定（169 / 71）が通るか
7. **ネットワークドライブ**: 元データを全件スキャンして XML のハッシュを計算する時間（処理済みの再実行にかかる時間の目安）

## 6. 実機での結果（2026-10-18〜19、i5-9400F・Windows 11）

テストデータは XML 25 文書（アーカイブと対の XML）＋ HTML 3 文書。比較の相手は、同じ入力から
Linux（Docker）で作った文書ストア。最初は手元にあった古いもの（libefiling 0.3.0、`NOIR_EMBEDDING_MAX_SEQ_LENGTH=0`）と比べ、
最後に Windows と同じ libefiling 0.3.1・既定の設定で Linux で作り直したものと比べた。

| # | 結果 | 時間 | つまずいたこと → 対処 |
| --- | --- | --- | --- |
| 1 | 通った | `uv lock` 2 秒、`uv sync --all-packages` 119 秒 | `requires-python >=3.12` のせいで uv が 3.12 を選び、queen・violet（`os.process_cpu_count`）と cendrillon（PEP 649 前提の注釈）が起動しなかった → `.python-version`=3.14、`requires-python >=3.14`。clone した作業ツリーが CRLF になっていた → `.gitattributes` |
| 2 | 全部通った（Python 12 パッケージ・fox・joker） | Python 合計 約 95 秒、vitest 各 5 秒 | なし（violet の CLIP を落とすテスト 1 件は Linux と同じく skip） |
| 3 | 通った。fail 0、ES に documents 28・images 149。joker の keyword・hybrid・画像セマンティック検索、fox の表示、nginx 経由の navi・skull | 1 回目 511 秒（モデルのダウンロード込み）、2 回目 184 秒 | fox が 404 → `FOX_BASE_PATH=/fox` でビルド。`FOX_URL` が navi と joker で意味が違う → joker にだけ launcher の設定で渡す。nginx の Windows 用の設定が無かった → `nginx.windows.conf`。ES 9 が HTTPS とパスワードを自動で有効にする → `elasticsearch.yml`（§1） |
| 4 | 下記 | diff-store 15 秒 | libefiling と queen が XML と manifest を CRLF で書いていた。libefiling が manifest の並びを glob の順のままにしていた → queen を直し、libefiling は 0.3.1 で直した |
| 5 | 下記。25 文書の規模では、Defender の除外の前と後でほぼ変わらない | | 起動し直した直後の noir は、torch とモデルの読み込みに約 1 分かかることがある（`uv sync` の直後など、ディスクのキャッシュが冷えているとき）。埋め込みそのものは 25 文書で約 18 秒 |
| 6 | 通った | | 元データの最長パス 119 文字、HTML の元データ 210 文字（ファイル名 cp932 で 176 バイト）、文書ストア 160 文字。いずれも 260 文字未満。cendrillon の取り込みはテストデータの HTML 3 件で成功 |
| 7 | 通った | 列挙 24.0 秒 ＋ XML 836 件のハッシュ 30.6 秒 ＝ 54.6 秒 | 元データの共有には作業用のフォルダ（展開結果・ダミー）も入っていて、crow は再帰的にたどるので、それも拾う。`SRC_DIR` はそれらを含まない場所にする |

**4 の詳細（同一性）。** 直したあとの状態。Linux も libefiling 0.3.1・既定の設定で作ったものとの比較（2026-10-19）では、**差は OCR テキスト（6 文書）だけ**になった:

| 対象 | 結果 |
| --- | --- |
| `document.json`・`images-information.json`・`document-properties.json`（ベクトル以外）・`doc.json`・`img.json`、`raw/`、`xml/` | **一致**（XML もバイト単位で一致） |
| 画像のベクトル（CLIP） | 一致（コサイン 0.999 以上） |
| 文書のベクトル（ruri） | 一致（最小コサイン 1.000000）。古い比較の相手は `NOIR_EMBEDDING_MAX_SEQ_LENGTH=0`（切らない）で作られていたため 7 件がコサイン 0.958〜0.997 になったが、設定をそろえれば一致する |
| `manifest.json` | 一致（違うのは `generator.created_at` だけで、diff-store は既定で比べない）。libefiling 0.3.0 で作ったものとは `xml_files`・`images` の並び順が違う（0.3.1 でファイル名順にしたため）ので、比べる2つは libefiling の版をそろえること |
| OCR テキスト | **一致しない（既知の差）。** 学習データを Linux と同じ tessdata_fast にすると、似ている度合い（difflib）の平均が 0.68 → 0.96、48 枚の OCR が 312 → 156 秒。tesseract を 5.4.0 → 5.5.0 にしても変わらない。同じ機械の WSL の Docker（Linux 版 5.5.0、leptonica 1.84.1）で同じ画像を OCR すると比較の相手と 44/48 が一致（平均 0.9995）するので、残りの差は Windows 版（UB Mannheim、leptonica 1.85.0）のビルドによるもの。Windows ネイティブで OCR を Linux とそろえる方法は無い |

**5 の詳細（性能）。** 文書ストアを空にし、launcher を起動し直してから流した（モデルはキャッシュ済み）。WSL の phantom は止めた状態。
除外の前は tesseract 5.4.0、後は 5.5.0（どちらも学習データは tessdata_fast）:

| | Linux（Ryzen 3 4300G、2026-08-11） | Windows（i5-9400F、除外なし） | Windows（除外あり） |
| --- | --- | --- | --- |
| queen | 9.6 秒 | 10.1 秒 | 9.3 秒 |
| noir | 23.9 秒 | 30.2 秒 | 30.9 秒 |
| violet | 69.9 秒 | 77.0 秒 | 80.9 秒 |

**全件の取り込み（2026-10-19）。** 元データの共有（`SRC_DIR` に共有のトップを指定、作業用のフォルダも含む）を、
空の文書ストア（`var\data-full`）と別のインデックス（`documents-full` / `images-full`）に流した。
Defender の除外あり、WSL の phantom は止めた状態:

| 段 | 時間 | 件数 |
| --- | --- | --- |
| crow | 80.0 秒 | 836 件のうち取り込み 191、スキップ 645（文書 ID のかぶり 136、ホワイトリストの対象外 約 509） |
| queen | 49.3 秒 | 191 |
| noir | 190.1 秒 | 191 |
| violet | 248.1 秒 | 191（画像 819 枚） |
| cendrillon | 49.7 秒 | 3（テストデータの HTML） |
| panther | 60.0 秒 | 194 |
| **合計** | **683 秒（約 11 分）** | fail 0。文書ストア 178 MB |

取り込みの対象になるのは、ホワイトリストを通った約 190 件（元データ約 700 件のうち）。1 文書あたり約 3.5 秒。

**メモリ（W7）。** 5 秒ごとに、各サービスのプロセスツリーのコミット済みのプライベート（ワーキングセット）を記録した:

| | 待機中 | 全件の取り込み中の最大 |
| --- | --- | --- |
| crow・mona・navi・skull・panther・cendrillon（各） | 80〜120 MB | 80〜130 MB |
| fox・joker（各） | 約 90 MB | 約 50 MB |
| queen | 155 MB | 1.0 GB（ワーキングセット 0.65 GB） |
| noir | 83 MB | 1.7 GB（1.0 GB）。モデルを読んだあとは常駐する |
| **violet** | 86 MB | **10.6 GB（3.8 GB）**。画像のワーカー 4 つがそれぞれ CLIP を読むため（spawn）。タスクが終わると 2 GB に下がり、cendrillon からの依頼で本体が CLIP を読むと 4.2 GB で常駐する |
| Elasticsearch（ヒープ 4 GB） | 4.6 GB | 4.7 GB |
| phantom ＋ ES ＋ nginx の合計 | 5.7 GB | **18.0 GB** |

32 GB の機械で、ほかのアプリ（ブラウザ・WSL の Ubuntu など）を含むシステム全体の使用量は最大 28.7 GB だった。
落ちはしなかったが余裕は少ない。第2段階で CLIP を lavenza の1か所にまとめると、この問題はなくなる
（[設計書](python-new-loop-design.md) §2.2）。

**メモリを絞った設定（16 GB の機械向け）。** 同じ全件を、次の設定で流し直した（2026-10-19）。
出力は上の全件と同じ（diff-store で 194 文書とも差分なし、ベクトルの最小コサイン 1.000000）:

```ini
# .env
VIOLET_IMAGE_WORKERS=1
QUEEN_IMAGE_WORKERS=2
```

```text
# <ES>\config\jvm.options.d\heap.options
-Xms2g
-Xmx2g
```

| | 既定（violet 4・queen 5・ES 4 GB） | 絞った設定（violet 1・queen 2・ES 2 GB） |
| --- | --- | --- |
| 合計の時間 | 683 秒（約 11 分） | 1,032 秒（約 17 分） |
| violet | 248 秒・最大 10.6 GB | 654 秒・最大 4.3 GB |
| queen | 49 秒・最大 1.0 GB | 61 秒・最大 0.7 GB |
| noir | 190 秒・最大 1.7 GB | 148 秒・最大 1.7 GB |
| Elasticsearch | 4.7 GB | 2.6 GB |
| **phantom ＋ ES ＋ nginx のピーク** | **18.0 GB** | **9.6 GB** |

絞った設定なら、Windows 本体と常駐のアプリに 4〜5 GB を見ても **16 GB の機械で動かせる**（16 GB の実機では未確認）。
代わりに全件の取り込みは約 1.5 倍かかり、その大半は violet。

**第2段階: lavenza（2026-10-19）。** noir・violet のモデルを lavenza（モデルサーバー、ポート 8009）にまとめたあと、
同じ全件を同じ条件（既定のワーカー数、ES ヒープ 4 GB）で流した。出力は切り替える前と同じ（diff-store で 194 文書とも差分なし）:

| | 切り替える前 | lavenza |
| --- | --- | --- |
| 合計の時間 | 683 秒 | 639 秒 |
| noir | 190 秒・最大 1.7 GB | 150 秒・最大 0.1 GB |
| violet | 248 秒・最大 10.6 GB | 273 秒・最大 1.2 GB（OCR のワーカーだけ） |
| lavenza | — | 最大 3.3 GB（ruri ＋ CLIP の画像タワー） |
| **phantom ＋ ES ＋ nginx のピーク** | **18.0 GB** | **10.3 GB** |

lavenza は、検索フレーズの変換を頼まれるまで CLIP の画像タワーだけを読む。joker で画像のセマンティック検索をすると
両タワーを読むので、そのぶん（1 GB 強）増える。ワーカー数を絞らなくても 16 GB の機械に収まる見込み。
lavenza は起動したら裏でモデルを読む（`LAVENZA_PRELOAD`。この機械で約 23 秒）ので、取り込みをしていない待機中から 3.3 GB ほど使う。

**第2段階: 新しいループ（2026-10-19）。** navi の `POST /api/runs` で同じ全件を流すと、並列度の既定値
（文書 4・OCR 4・画像変換 4・torch は既定）で **497 秒**（取り込みが分かれていたころは 639 秒）、fail 0。出力は分かれていたころと同じ
（diff-store で 194 文書とも差分なし）。テストデータ（28 文書）は約 100 秒。並列度の組み合わせごとの時間は
[設計書](python-new-loop-design.md) §3 の 9。

## 既知の制限

- `npm start`（fox・joker）は POSIX シェルの書き方なので Windows では動かない。launcher は `node dist/server/entry.mjs` を直接起動する
- launcher をコンソール無し（`phantom-launcherw`）で動かしているときは、子プロセスに停止の合図を送れないので、
  `down` は各サービスを `taskkill /T /F` で止める。タスクの状態は taskservice が JSON で保存しているので、
  止めたタスクは次回やり直せばよい
- Docker の `mem_limit` に相当する保護は無い。実測のメモリは §6 の「メモリ（W7）」、目安は [設計書](python-new-loop-design.md) §2.9
- Windows では huggingface_hub がシンボリックリンクを使えず、モデルのキャッシュがファイルの複製になる（警告が出るだけで動作には影響しない）
- 文書ストアと manifest を Linux とバイト単位でそろえるには、libefiling 0.3.1 以上が要る（navi の依存は `>=0.3.1`）
- OCR テキストは Linux と少し違う（上の §6 の 4）
