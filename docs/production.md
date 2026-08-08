# 本番環境のセットアップ

`docker-compose.yml` 一式で、パイプライン・検索・閲覧・メタ情報管理と
Elasticsearch をまとめて動かす。ホストに出るのは nginx の1ポートだけで、
サービス間の通信は `phantom-network` の中で完結する。

開発環境については [開発環境の用意](development.md) を参照。

## 前提

| | 目安 |
| --- | --- |
| Docker Engine + Compose v2 | 最新 |
| メモリ | Elasticsearch に 4 GB（`ES_MEM_LIMIT`）+ noir / violet のモデル分で 8 GB 以上 |
| ディスク | 文書ストア（文書1件あたり数百 KB〜数 MB）+ ES インデックス + モデルキャッシュ数 GB |

Elasticsearch のためにホスト側の設定を1つ入れる。

```bash
sudo sysctl -w vm.max_map_count=262144
echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-phantom.conf
```

## 1. ファイルを配置する

運用に必要なのは `docker-compose.yml`・`infra/nginx/nginx.conf`・`infra/es/` と
`.env.docker` だけ。リポジトリをそのまま clone してもよいし、
[phantom-release](https://github.com/hyperion13th144m/phantom-release)
（イメージのダイジェストを固定したデプロイ用リポジトリ）を使ってもよい。

```bash
git clone https://github.com/hyperion13th144m/phantom.git
cd phantom
```

イメージは GitHub Actions が `ghcr.io/hyperion13th144m/phantom-<service>` に push している。
非公開パッケージの場合は先にログインする。

```bash
docker login ghcr.io
```

## 2. ホスト側のディレクトリを用意する

コンテナは uid=gid=1000 で動くので、書き込み先は 1000 が書けるようにしておく。

```bash
# 展開先（crow / queen / noir / violet が書き、mona / panther が読む）
sudo install -d -o 1000 -g 1000 /var/lib/phantom/data
```

電子データを置くディレクトリ（`PHANTOM_SRC_DIR`）は read-only でマウントされるので、
読めれば十分。

## 3. `.env.docker` を作る

```bash
cp .env.docker.sample .env.docker
```

リポジトリ直下の `.env` は開発用（`$HOME` を含むパスがある）なので compose には使わない。
**compose のコマンドは毎回 `--env-file .env.docker` を付ける。**

最低限、次を自分の環境に合わせる。

| 変数 | 説明 |
| --- | --- |
| `PHANTOM_SRC_DIR` | インターネット出願ソフトの電子データの場所（read-only でマウント） |
| `PHANTOM_DATA_DIR` | 文書ストアの場所 |
| `PHANTOM_HTTP_PORT` | nginx が待ち受けるホスト側ポート（既定 8080） |
| `PHANTOM_PUBLIC_URL` | ブラウザから見える phantom のベース URL。joker が fox へのリンクを組み立てるのに使う |
| `ES_PASSWORD` | Elasticsearch のパスワード |

`ES_JAVA_OPTS` / `ES_MEM_LIMIT` はホストの搭載メモリに合わせて調整する
（ヒープは物理メモリの半分以下、かつ `ES_MEM_LIMIT` より小さく）。

## 4. 起動する

Elasticsearch だけは、マッピングが使うプラグイン（`analysis-kuromoji` /
`analysis-icu`）を入れたイメージを `infra/es/Dockerfile` からローカルでビルドする。
残りは ghcr から取得する。

```bash
docker compose --env-file .env.docker build es
docker compose --env-file .env.docker pull --ignore-buildable
docker compose --env-file .env.docker up -d
docker compose --env-file .env.docker ps
```

インデックス（`documents` / `images`）は panther が
`ES_MAPPING_DIR`（コンテナ内 `/infra/es`）のマッピングから自動で作る。
マッピングファイルが無ければタスクを開始しない
（dynamic mapping で型が壊れるのを防ぐため）。

## 5. 公開されるパス

ホストに出るのは nginx の `PHANTOM_HTTP_PORT` だけ。
ルーティングは [infra/nginx/nginx.conf](../infra/nginx/nginx.conf) に定義されている。

| パス | 転送先 | 内容 |
| --- | --- | --- |
| `/` | joker | 検索 UI・検索 API |
| `/fox/` | fox | 文書ビューア |
| `/skull/` | skull | メタ情報管理 UI |
| `/navi/` | navi | パイプライン管制 UI |
| `/api/contents/` | mona | 文書コンテンツ（JSON・画像） |
| `/api/meta`・`/api/links`・`/api/group-links`・`/api/unmatched`・`/tasks` | skull | skull の UI が絶対パスで叩く API |
| `/api/services`・`/api/pipeline` | navi | navi の UI が絶対パスで叩く API |

fox は `base=/fox` でビルドされたイメージなので、プレフィックスごと転送している
（`FOX_BASE_PATH` ビルド引数）。skull / navi はプレフィックスを外して転送する。

phantom 自体は認証を持たない。インターネットに出す場合は、
nginx の手前で Basic 認証・VPN・Cloudflare Access などを挟むこと。

## 6. 最初の取り込み

`http://<host>:<PHANTOM_HTTP_PORT>/navi/` を開いて「パイプライン開始」を押すと、
crow → queen → noir → violet → panther が順に走る。
初回は noir / violet のモデルが HuggingFace からダウンロードされるので、
最初の1件に数分かかることがある（`hf-cache` ボリュームに残るので次回以降は速い）。

終わったら `/` で検索でき、`/skull/` でメタ情報を付与できる。
操作の詳細は [運用方法](operations.md) を参照。

## 更新

```bash
docker compose --env-file .env.docker pull --ignore-buildable
docker compose --env-file .env.docker up -d
```

文書ストアと Elasticsearch のデータは残るので、再取り込みは不要。
各サービスは既存の出力があればスキップするため、`up -d` の後にパイプラインを
流し直しても差分だけが処理される。

なお、パイプラインの実行状態は navi のメモリ上にしか無いので、
navi を再起動すると一括実行のチェーンは失われる（各サービスのタスク状態自体は
永続化されているので、UI から続きを手動で開始できる）。

## リリース（phantom-release の更新）

`.github/workflows/update-release.yml` を `workflow_dispatch` で実行すると、
ghcr の各イメージのダイジェストを解決して `docker-compose.yml` に固定し、
運用に必要なファイルだけを phantom-release リポジトリにコピーして
バージョンタグと GitHub Release を作る。ダイジェスト固定なので、
同じタグからいつでも同一の構成を再現できる。

## ログ

```bash
docker compose --env-file .env.docker logs -f crow
docker compose --env-file .env.docker logs -f --tail=100
```

`LOG_LEVEL`（既定 `INFO`）を `DEBUG` にすると Python サービスの出力が詳しくなる。
fox / joker は `LOG_DIR_FOX` / `LOG_DIR_JOKER`（`fox-log` / `joker-log` ボリューム）に
ファイル出力する。

## ボリュームとバックアップ

| ボリューム | 内容 | バックアップ |
| --- | --- | --- |
| `${PHANTOM_DATA_DIR}`（ホストのディレクトリ） | 文書ストア（展開済み文書・画像・JSON） | 必要。失うと再取り込みになる |
| `skull-data` | メタ情報 DB（SQLite）とタスク状態 | **必須。ここだけは再生成できない** |
| `es-data` | Elasticsearch のインデックス | 任意（パイプライン再実行で再生成できる） |
| `crow-state` / `queen-state` / `noir-state` / `violet-state` / `panther-state` | タスクの進捗・履歴 | 不要 |
| `fox-config` | fox の表示設定 | 任意 |
| `fox-log` / `joker-log` | アクセスログ | 任意 |
| `hf-cache` | HuggingFace のモデル重み | 不要（再ダウンロードされる） |

skull の DB は SQLite が既定だが、`SKULL_DB_URL` に
`postgresql+psycopg://user:pass@host/dbname` を指定すれば PostgreSQL に切り替えられる。

```bash
# 例: skull の DB をコピーする
docker run --rm -v skull-data:/data -v "$PWD":/backup alpine \
  tar czf /backup/skull-data.tar.gz -C /data .
```

## モデルを変更する場合

noir のエンベディングモデル（`NOIR_EMBEDDING_MODEL`）を変えると次元数が変わるため、
Elasticsearch のマッピング（`infra/es/doc-mapping.json` の `embeddings.dims`）も
合わせて変更し、`json/document-properties.json` を消して再実行する必要がある。
ruri 系以外のモデルではプレフィックス（`NOIR_EMBEDDING_DOC_PREFIX` /
`NOIR_EMBEDDING_QUERY_PREFIX`）も合わせること。詳細は
[noir の README](https://github.com/hyperion13th144m/phantom/blob/main/services/noir/README.md) を参照。
