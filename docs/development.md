# 開発環境の用意

ローカルで phantom 一式（取り込み navi・モデルサーバー queen・メタ情報 skull・フロント3サービス）を
動かすまでの手順。本番構築は [本番環境のセットアップ](production.md) を参照。

## 必要なもの

| | バージョン | 用途 |
| --- | --- | --- |
| Python | 3.14 以上 | navi / queen / skull / mona |
| [uv](https://docs.astral.sh/uv/) | 最新 | Python 側のワークスペース管理・実行 |
| Node.js | 22.12 以上 | fox / joker（Astro SSR） |
| Docker | 最新 | Elasticsearch を動かす |
| tesseract | 5 系 | navi の OCR |

tesseract は本体と日本語データが必要。

```bash
sudo apt install tesseract-ocr tesseract-ocr-jpn
tesseract --list-langs   # eng / jpn が出ること
```

ディスクは、依存関係（torch の CPU wheel・HuggingFace のモデル）に数 GB、
文書ストアに文書1件あたり数百 KB〜数 MB を見ておく。

## 1. 依存関係のインストール

```bash
git clone https://github.com/hyperion13th144m/phantom.git
cd phantom
uv sync --all-packages
```

`--all-packages` は必須。uv workspace なので、素の `uv sync` ではルートの依存しか入らず、
各サービスのコマンド（`uv run navi` など）が使えない。**サービスを追加したときも
`uv sync --all-packages` を実行し直すこと。**

fox / joker は npm プロジェクトで、workspace からは除外されている
（ルート `pyproject.toml` の `[tool.uv.workspace] exclude`）。

```bash
(cd services/fox   && npm install)
(cd services/joker && npm install)
```

## 2. 環境変数

`.env.sample` をコピーして編集する。全サービスの環境変数がここに1つにまとまっている。

```bash
cp .env.sample .env
```

最低限、次の3つを自分の環境に合わせる。

| 変数 | 説明 |
| --- | --- |
| `SRC_DIR` | インターネット出願ソフトの電子データがある場所（navi が読む） |
| `DST_DIR` | 文書ストア。navi が書き、mona・queen が読む |
| `ES_URL` / `ES_USER` / `ES_PASSWORD` | Elasticsearch への接続 |

`NAVI_STATE_DIR`・`SKULL_STATE_DIR`（実行の履歴・タスク状態の保存先）と `SKULL_DB_URL` は既定値が `/var/lib/...` なので、
開発時はリポジトリ配下に向けておくと権限で困らない。`PHANTOM_HOME` を1つ指定すれば、
個別に指定していないものはまとめてその下（`$PHANTOM_HOME/<サービス>/...`）に置かれる。

読み込みは [direnv](https://direnv.net/) を使うのが楽で、リポジトリに `.envrc` が入っている。

```bash
direnv allow
```

direnv を使わない場合は、サービスを起動するシェルで読み込む。

```bash
set -a; source .env; set +a
```

`uv run` には `--env-file` もある（Windows でも同じ書き方で使える）。

```bash
uv run --env-file .env navi
```

全サービスをまとめて起動・停止したいときは [phantom-launcher](../scripts/launcher/README.md) を使う
（`.env` を読み、落ちたサービスを起動し直し、ログをファイルに残す）。

```bash
cp scripts/launcher/phantom-launcher.sample.toml phantom-launcher.toml
uv run phantom-launcher up --console
```

### ポートの割り当て

`.env.sample` の既定値は次のとおり。既に使っているポートとぶつかる場合は
`.env` 側で自由に変えてよい（`*_URL` も合わせて変えること）。

| サービス | 変数 | 既定 |
| --- | --- | --- |
| queen | `QUEEN_PORT` | 8001 |
| mona | `MONA_PORT` | 8002 |
| navi | `NAVI_PORT` | 8005 |
| skull | `SKULL_PORT` | 8007 |
| fox | `FOX_PORT` | 4321 |
| joker | `JOKER_PORT` | 4322 |

## 3. Elasticsearch を起動する

マッピングが `analysis-kuromoji` と `analysis-icu` を使うので、
プラグイン入りのイメージを `infra/es` からビルドして使う。

```bash
docker build -t phantom-elasticsearch infra/es

docker run -d --name phantom-es-dev \
  -p 9200:9200 \
  -e discovery.type=single-node \
  -e xpack.security.enabled=false \
  -e ES_JAVA_OPTS="-Xms512m -Xmx512m" \
  phantom-elasticsearch

curl localhost:9200/_cluster/health
```

インデックス（`documents` / `images`）は navi が
`ES_MAPPING_DIR`（`infra/es`）のマッピングから自動で作るので、手で作る必要はない。
マッピングの中身は [infra/es/README.md](../infra/es/README.md) を参照。

起動しない場合は `vm.max_map_count` を確認する。

```bash
sudo sysctl -w vm.max_map_count=262144
```

## 4. fox の型定義を生成する

fox は文書 JSON の型定義・型ガードを `libs/jpo-schema` の XSL から生成して使う
（`services/fox/src/interfaces/generated/` は git 管理外）。
**fox を動かす前に一度実行する。** XSL を更新したときも実行し直す。

```bash
./scripts/build-json-schema.sh   # XSL → JSON Schema  (var/generated/json-schema)
./scripts/build-ts-schema.sh     # JSON Schema → .ts / .guard.ts (var/generated/typescript)
./scripts/copy-ts-schema.sh      # fox の src/interfaces/generated へコピー
```

## 5. サービスを起動する

環境変数を読み込んだシェルで、それぞれ別ターミナル（あるいはバックグラウンド）で起動する。

```bash
uv run queen --port "$QUEEN_PORT"
uv run mona  --port "$MONA_PORT"
uv run skull --port "$SKULL_PORT"
uv run navi  --port "$NAVI_PORT"
```

fox / joker は Astro なので npm から起動する。開発中は `npm run dev`
（HMR つき。バインド先は `astro.config.mjs` の `server` で `FOX_HOST` / `FOX_PORT` を見る）、
本番相当の確認は `npm run build && npm start`。

```bash
(cd services/fox   && npm run dev)
(cd services/joker && npm run dev)
```

全部起動したら health を確認する。

```bash
for p in 8001 8002 8005 8007 4321 4322; do
  printf "%s: " "$p"; curl -s "http://localhost:$p/health"; echo
done
```

navi（既定 http://localhost:8005/ ）を開くと、取り込みの状況と各サービスの死活が1画面で確認できる。

## 6. 動かしてみる

`SRC_DIR` に電子データを置いた状態で navi の「取り込み開始」を押すと、
文書ごとに展開 → 変換 → 書誌 → 画像 → 登録が流れる。
まず少件数で試したいときは、「件数の上限」に件数を入れてから開始する。
詳しくは [運用方法](operations.md) を参照。

初回は queen が、文書のエンベディングモデル（`cl-nagoya/ruri-v3-130m`、数百 MB）と
画像の open_clip モデルを HuggingFace からダウンロードするので、
最初の1件だけ時間がかかる。

登録が終わったら joker（既定 http://localhost:4322/search ）で検索できる。
使い方は [検索の使い方](search.md) を参照。

## テスト

pytest はサービスごとに `conftest.py` があり、まとめて実行すると衝突する。
**パッケージ単位で実行すること。**

```bash
uv run --package navi  pytest services/navi/tests
uv run --package queen pytest services/queen/tests
uv run --package mona  pytest services/mona/tests
uv run --package skull pytest services/skull/tests
uv run --package phantom-launcher pytest scripts/launcher/tests
uv run pytest libs/python/taskservice/tests
uv run pytest libs/python/whitelist/tests
```

fox / joker は vitest。

```bash
(cd services/fox   && npm test)
(cd services/joker && npm test)
```

## lint / format

```bash
uvx ruff check libs services
uvx ruff format libs services
```

## つまずきやすいところ

- **`uv run <service>` が見つからない** — `uv sync --all-packages` を実行していない。
  サービスを追加した直後も同じ。
- **`operator torchvision::nms does not exist`** — queen の torch は
  `pytorch-cpu` index の CPU wheel を使う。`tool.uv.sources` は直接依存にしか効かないので、
  `torchvision` も明示的に依存に入れて同じ index を指定する必要がある
  （`services/queen/pyproject.toml` 参照）。
- **navi が XSL を見つけられない** — 既定では `libs/jpo-schema/stylesheets/2.0` を
  自動検出する。別の場所に置く場合は `XSL_DIR` で指定する。
- **セマンティック検索が失敗する** — joker はクエリのベクトル化を queen の
  `POST /noir/embeddings/query`（画像は `/violet/embeddings/query`）に投げるので、
  queen が起動している必要がある（`QUEEN_URL`）。
- **取り込みの書誌・画像・HTML の段が全件失敗になる** — navi はモデルを持たず、
  エンベディングを queen に頼む。queen が起動していて `QUEEN_URL` が正しいこと、
  そして queen が navi と同じ `DST_DIR` を見ていることを確認する（画像は本体ではなく在り処を送る）。
- **fox の型エラー** — `scripts/copy-ts-schema.sh` まで実行して
  `services/fox/src/interfaces/generated/` を作る。
- **取り込みを途中の段から流し直したい** — 各段は出力 JSON の有無で
  処理済みを判定する。作り直したい文書の
  `json/document.json`（変換）/ `document-properties.json`（書誌）/
  `images-properties.json`（画像）と、`doc.json`・`img.json`（登録）を消して再実行する。
