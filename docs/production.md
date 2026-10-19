# 本番環境のセットアップ

`docker-compose.yml` 一式で、取り込み・検索・閲覧・メタ情報管理と
Elasticsearch をまとめて動かす。ホストに出るのは nginx の1ポートだけで、
サービス間の通信は `phantom-network` の中で完結する。

開発環境については [開発環境の用意](development.md) を参照。

## 前提

| | 目安 |
| --- | --- |
| Docker Engine + Compose v2 | 最新 |
| メモリ | **16 GB 推奨**（最低 8 GB）。下の「メモリの見積もり」を参照 |
| OS | Linux。Windows の場合は「[Windows の場合](#windows-の場合)」を参照 |
| ディスク | 文書ストア（文書1件あたり数百 KB〜数 MB）+ ES インデックス + モデルキャッシュ数 GB |

### メモリの見積もり

エンベディングのモデル（ruri と CLIP）は queen（モデルサーバー）だけが持ち、
navi の取り込みと joker の検索がどちらも HTTP で使う
（テキストは `POST /noir/embeddings/document`、画像は `POST /violet/embeddings/image`）。
queen は検索クエリの変換にも使うので、モデルを読んだあと常駐させ続ける。

| サービス | 目安 | 備考 |
| --- | --- | --- |
| queen | 常駐 3.3 GB、ロード時ピーク 4.5 GB 程度 | ruri 0.7 GB ＋ CLIP の画像タワー。joker で画像のセマンティック検索をすると、テキストタワーのぶん 1 GB 強増える |
| navi | 0.5 GB 前後（上限 2 GB） | XSLT の saxonche がプロセス内に JVM を持つ。画像変換のワーカーと tesseract も navi の中 |
| Elasticsearch | 1.2 GB | ヒープ 2 GB 指定時 |
| joker / fox / skull / mona / nginx | 各 50〜100 MB | |

**`QUEEN_MEM_LIMIT` は常駐ではなくロード時ピークに合わせること。** open_clip の
checkpoint は safetensors が用意されておらず、1.4 GB の `.bin` を `torch.load`
するため、空のモデル本体と読み込んだ重みが一瞬だけ二重に乗る。queen に 4 GB 以下を割り当てると、
ロードの最中に OOM kill されて起動と再起動を繰り返す（ログは `Loading full pretrained weights from: ...` の直後で切れ、
`exited with code 137` になる）。

画像は本体を送らずに在り処だけを送るので、navi と queen が同じ `PHANTOM_DATA_DIR` をマウントしていることが前提になる。

**16 GB** あれば何も考えずに運用できる。使えるメモリが 10 GB 前後の場合は `ES_JAVA_OPTS=-Xms1g -Xmx1g` /
`ES_MEM_LIMIT=2g` にする。

各コンテナには `mem_limit` と `memswap_limit` を同じ値で設定してある。
**memswap_limit を揃えるとそのコンテナはスワップを使わなくなる**ので、
上限を超えたコンテナはスワップに逃げずに OOM kill され、`restart: unless-stopped`
で戻る。1つのサービスがスワップを食い潰してホスト全体が反応しなくなるのを
防ぐための設定なので、外さないこと。値は `.env.docker` の `*_MEM_LIMIT` で調整する。

Elasticsearch のためにホスト側の設定を1つ入れる（Linux ホストの場合）。

```bash
sudo sysctl -w vm.max_map_count=262144
echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-phantom.conf
```

## Windows の場合

Windows では Docker・WSL を使わずに直接動かす。手順は [Windows ネイティブで動かす](windows-native.md) を参照
（Elasticsearch と nginx を Windows 版で入れ、phantom のサービスは phantom-launcher で起動する）。
以前は Docker Desktop + WSL2 で動かす手順をここに書いていたが、メモリの割り当て（`.wslconfig`）・
WSL の中の Docker から Hugging Face への通信・ファイルの置き場所で手間がかかるので、Windows ネイティブに置き換えた。

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
# 文書ストア（navi が書き、mona・queen が読む）
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
| `PHANTOM_HTML_SRC_DIR` | XML が無く HTML + 画像しか残っていない文書の場所（read-only）。無ければ `PHANTOM_SRC_DIR` と同じでよい |
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

インデックス（`documents` / `images`）は navi が取り込みの最初に
`ES_MAPPING_DIR`（コンテナ内 `/infra/es`）のマッピングから自動で作る。
マッピングファイルが無ければ取り込みを始めない
（dynamic mapping で型が壊れるのを防ぐため）。
ES が healthy になってからも navi から繋がるまで数十秒かかることがあるので、取り込みの最初に
繋がらなければ `NAVI_ES_WAIT_TIMEOUT`（既定 60 秒）まで待ってやり直す。

navi は `infra/whitelist/white-list.json` を取り込みのたびに読み、そこに
無い書類は取り込まない。このファイルはイメージに焼いてある（コンテナ内
`/infra/whitelist`）ので、取り込む書類を増やしたらリポジトリを更新して
イメージを入れ替える。作り方は
[infra/whitelist/README.md](../infra/whitelist/README.md) を参照。

## 5. 公開されるパス

ホストに出るのは nginx の `PHANTOM_HTTP_PORT` だけ。
ルーティングは [infra/nginx/nginx.conf](../infra/nginx/nginx.conf) に定義されている。

| パス | 転送先 | 内容 |
| --- | --- | --- |
| `/` | joker | 検索 UI・検索 API |
| `/fox/` | fox | 文書ビューア |
| `/skull/` | skull | メタ情報管理 UI |
| `/navi/` | navi | 取り込みの管理 UI |
| `/api/contents/` | mona | 文書コンテンツ（JSON・画像） |
| `/api/meta`・`/api/links`・`/api/group-links`・`/api/unmatched`・`/tasks` | skull | skull の UI が絶対パスで叩く API |
| `/api/services`・`/api/runs` | navi | navi の UI が絶対パスで叩く API |

fox は `base=/fox` でビルドされたイメージなので、プレフィックスごと転送している
（`FOX_BASE_PATH` ビルド引数）。skull / navi はプレフィックスを外して転送する。

phantom 自体は認証を持たない。インターネットに出す場合は、
nginx の手前で Basic 認証・VPN・Cloudflare Access などを挟むこと。

## 6. 最初の取り込み

`http://<host>:<PHANTOM_HTTP_PORT>/navi/` を開いて「取り込み開始」を押すと、
文書ごとに展開 → 変換 → 書誌 → 画像 → 登録が流れ、終わった文書から検索に出る。
初回は queen が起動したときにモデルを HuggingFace からダウンロードするので、
数分かかることがある（`hf-cache` ボリュームに残るので次回以降は速い。queen の health の `models` が
`loaded` になってから始めるとよい）。

定期的に取り込むなら、cron から `curl -X POST http://localhost:<PHANTOM_HTTP_PORT>/api/runs` を叩く。

終わったら `/` で検索でき、`/skull/` でメタ情報を付与できる。
操作の詳細は [運用方法](operations.md) を参照。

## 更新

```bash
docker compose --env-file .env.docker pull --ignore-buildable
docker compose --env-file .env.docker up -d
```

文書ストアと Elasticsearch のデータは残るので、再取り込みは不要。
取り込みの各段は既存の出力があればスキップするため、`up -d` の後に取り込みを
流し直しても差分だけが処理される。取り込みの途中で navi を再起動した場合も、もう一度始めれば続きから処理される。

### 取り込みが複数のサービスに分かれていたころから更新する場合

2026-10 に、取り込みの各段を受け持っていた crow・queen・noir・violet・panther・cendrillon を navi に統合し、
モデルサーバーの lavenza を queen に改名した（ポート 8001）。文書ストアと Elasticsearch のデータはそのまま使える。

- 新しい `docker-compose.yml` で `up -d --remove-orphans` すると、消えたサービスのコンテナが止まって消える
- タスク状態のボリューム（`crow-state`・`queen-state`・`noir-state`・`violet-state`・`cendrillon-state`・`panther-state`）は
  使わなくなるので、`docker volume rm` で消してよい
- `.env.docker` の `LAVENZA_*` は `QUEEN_*` に読み替える（`LAVENZA_MEM_LIMIT` → `QUEEN_MEM_LIMIT` など）
- `hf-cache` ボリュームのモデルはそのまま使える。ただし、noir・violet がモデルを持っていたころのキャッシュには
  queen の目印（`queen-models.json`）が無いので、最初の起動だけ Hugging Face に更新を問い合わせる。
  Hugging Face に繋がりにくい環境（WSL の中の Docker で実際に起きた）では、queen の health の `models` が
  `loading` のまま数分以上進まなかったり `failed` になったりする。そのときは `.env.docker` に `HF_HUB_OFFLINE=1` を足して
  `up -d` し直す。一度読めれば目印が書かれるので、その後は外してよい

## リリース（phantom-release の更新）

`.github/workflows/update-release.yml` を `workflow_dispatch` で実行すると、
ghcr の各イメージのダイジェストを解決して `docker-compose.yml` に固定し、
運用に必要なファイルだけを phantom-release リポジトリにコピーして
バージョンタグと GitHub Release を作る。ダイジェスト固定なので、
同じタグからいつでも同一の構成を再現できる。

## ログ

```bash
docker compose --env-file .env.docker logs -f navi
docker compose --env-file .env.docker logs -f --tail=100
```

`LOG_LEVEL`（既定 `INFO`）を `DEBUG` にすると Python サービスの出力が詳しくなる。
fox / joker は `LOG_DIR_FOX` / `LOG_DIR_JOKER`（`fox-log` / `joker-log` ボリューム）に
ファイル出力する。

サービスが勝手に再起動している場合は、メモリ上限に当たって OOM kill された
可能性がある。`OOMKilled` が `true` なら `.env.docker` の `*_MEM_LIMIT` を上げる。
ログに `exited with code 137` が出ていれば、`OOMKilled` の値によらず OOM kill
とみなしてよい（下のコマンドは*いま動いている*コンテナの状態を見るので、
`restart: unless-stopped` で再起動したあとだと `false` に戻っている）。

```bash
docker inspect --format '{{.Name}} OOMKilled={{.State.OOMKilled}} restarts={{.RestartCount}}' \
  $(docker compose --env-file .env.docker ps -q)
```

いま各コンテナがどれだけ使っているかは次で見る。

```bash
docker stats --no-stream
```

## ボリュームとバックアップ

| ボリューム | 内容 | バックアップ |
| --- | --- | --- |
| `${PHANTOM_DATA_DIR}`（ホストのディレクトリ） | 文書ストア（展開済み文書・画像・JSON） | 必要。失うと再取り込みになる |
| `skull-data` | メタ情報 DB（SQLite）とタスク状態 | **必須。ここだけは再生成できない** |
| `es-data` | Elasticsearch のインデックス | 任意（取り込みの登録の段を流し直せば再生成できる） |
| `navi-state` | 取り込みの実行の履歴 | 不要 |
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

文書のエンベディングモデル（`NOIR_EMBEDDING_MODEL`、queen が読む）を変えると次元数が変わるため、
Elasticsearch のマッピング（`infra/es/doc-mapping.json` の `embeddings.dims`）も
合わせて変更し、`json/document-properties.json` を消して再実行する必要がある。
ruri 系以外のモデルではプレフィックス（`NOIR_EMBEDDING_DOC_PREFIX` /
`NOIR_EMBEDDING_QUERY_PREFIX`）も合わせること。詳細は
[queen の README](https://github.com/hyperion13th144m/phantom/blob/main/services/queen/README.md) を参照。
