# 本番環境のセットアップ

`docker-compose.yml` 一式で、パイプライン・検索・閲覧・メタ情報管理と
Elasticsearch をまとめて動かす。ホストに出るのは nginx の1ポートだけで、
サービス間の通信は `phantom-network` の中で完結する。

開発環境については [開発環境の用意](development.md) を参照。

## 前提

| | 目安 |
| --- | --- |
| Docker Engine + Compose v2 | 最新 |
| メモリ | **16 GB 推奨**（最低 8 GB）。下の「メモリの見積もり」を参照 |
| OS | Linux。Windows の場合は Docker Desktop + WSL2 で動くが、先に「[Windows（Docker Desktop + WSL2）の場合](#windowsdocker-desktop--wsl2の場合)」を読むこと |
| ディスク | 文書ストア（文書1件あたり数百 KB〜数 MB）+ ES インデックス + モデルキャッシュ数 GB |

### メモリの見積もり

エンベディングのモデルが大きく、noir と violet はモデルを読んだあと常駐させ続ける
（検索クエリの変換に使うため）。実測値は次のとおり。

| サービス | 常駐 | ロード時ピーク | 備考 |
| --- | --- | --- | --- |
| violet | 2.7 GB | 4.0 GB | open_clip xlm-roberta-base-ViT-B-32 |
| noir | 0.7 GB | 0.7 GB | cl-nagoya/ruri-v3-130m |
| Elasticsearch | 1.2 GB | — | ヒープ 2 GB 指定時 |
| queen | 0.4 GB | — | XSLT の saxonche がプロセス内に JVM を持つ |
| cendrillon / joker / fox / skull / navi / panther / crow / mona | 各 50〜100 MB | — | 合計 0.7 GB |

**`*_MEM_LIMIT` は常駐ではなくロード時ピークに合わせること。** open_clip の
checkpoint は safetensors が用意されておらず、1.4 GB の `.bin` を `torch.load`
するため、空のモデル本体と読み込んだ重みが一瞬だけ二重に乗る。常駐 2.7 GB の
violet に 3 GB を割り当てると、ロードの最中に OOM kill されて起動と再起動を
繰り返す（ログは `Loading full pretrained weights from: ...` の直後で切れ、
`exited with code 137` になる）。

**cendrillon はモデルを持たない。** HTML 入力でも埋め込みは XML 入力と同じ
モデルで作る必要があるので、テキストは noir の `POST /embeddings/document`、
画像とOCR は violet の `POST /embeddings/image` / `POST /ocr` に投げる。
同じモデルを2つのコンテナに常駐させずに済むぶん、cendrillon 自身は
Pillow しか積んでおらず 512 MB で足りる（以前は 3 GB 割り当てていた）。
画像は本体を送らずに在り処だけを送るので、cendrillon と violet が同じ
`PHANTOM_DATA_DIR` をマウントしていることが前提になる。

ピークはパイプライン実行中で約 7.5 GB。
OS と docker の分を足して **16 GB** あれば何も考えずに運用できる。

使えるメモリが 10 GB 前後の場合は `ES_JAVA_OPTS=-Xms1g -Xmx1g` /
`ES_MEM_LIMIT=2g` にする。それでピーク 7 GB 程度に収まり、パイプラインは
一括実行のままでよい（段ごとの積み上げは
「[16 GB のホストでの回し方](#16-gb-のホストでの回し方)」）。

各コンテナには `mem_limit` と `memswap_limit` を同じ値で設定してある。
**memswap_limit を揃えるとそのコンテナはスワップを使わなくなる**ので、
上限を超えたコンテナはスワップに逃げずに OOM kill され、`restart: unless-stopped`
で戻る。1つのサービスがスワップを食い潰してホスト全体が反応しなくなるのを
防ぐための設定なので、外さないこと。値は `.env.docker` の `*_MEM_LIMIT` で調整する。

Elasticsearch のためにホスト側の設定を1つ入れる（Linux ホストの場合。
Docker Desktop + WSL2 では既定で設定済みなので不要）。

```bash
sudo sysctl -w vm.max_map_count=262144
echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-phantom.conf
```

## Windows（Docker Desktop + WSL2）の場合

Windows でも動くが、下の手順に入る前に手当てが要る点が4つある。

### メモリを WSL2 に割り当てる

WSL2 は既定でホスト搭載メモリの50%しか VM に渡さない。phantom のピークは
約 9 GB なので、既定のままでは足りない。
`C:\Users\<ユーザー名>\.wslconfig` を作って割り当てを決める。

搭載 16 GB のノート PC の場合（Windows 本体に 6 GB 残す想定）:

```ini
[wsl2]
memory=10GB
processors=4
swap=8GB
```

搭載 32 GB あるなら `memory=16GB` にしてよく、その場合は後述の
「16 GB のホストでの回し方」は気にしなくてよい。

書いたら反映する。

```powershell
wsl --shutdown
```

そのあと Docker Desktop を再起動し、WSL 側で割り当てを確認する。

```bash
free -g && nproc
```

Docker Desktop の Settings → Resources → WSL Integration で、使う distro の
統合を有効にしておくこと。

### データは WSL の ext4 に置く（`/mnt/c` に置かない）

文書ストアは1文書あたり manifest + 元画像 + WebP 3サイズ + JSON 4つと、
小さいファイルが大量に並ぶ。`/mnt/c/...`（Windows ドライブ）は 9p 経由なので、
この形のアクセスが極端に遅くなる。`PHANTOM_DATA_DIR` は WSL の ext4 側に置く。

```bash
sudo install -d -o 1000 -g 1000 /var/lib/phantom/data
```

**リポジトリも WSL 内に clone すること。** compose が `./infra/es` と
`./infra/nginx/nginx.conf` を相対パスでバインドしているのと、git の autocrlf で
シェルスクリプトの改行が壊れるのを避けるため。

元データ（`PHANTOM_SRC_DIR`）が Windows 側にある場合、read-only マウントなので
`/mnt/c` のままでも動きはするが、取り込みのたびに全走査するので WSL 側に
コピーしたほうが速い。

### 日本語ファイル名が壊れていないか確かめる

[cendrillon](https://github.com/hyperion13th144m/phantom/blob/main/services/cendrillon/README.md) は **HTML のファイル名が cp932 で
169バイト（発送書類は71バイト）の固定長**であることを前提に、出願番号・受付番号・
提出日を取り出している。Windows 経由でコピーすると NTFS の UTF-16 → WSL の UTF-8
変換が挟まるので、取り込み前に長さを確かめておく。

```bash
find "$PHANTOM_SRC_DIR" -iname '*.HTM' -printf '%f\n' \
  | python3 -c "import sys; [print(len(l.rstrip().rsplit('.',1)[0].encode('cp932','replace'))) for l in sys.stdin]" \
  | sort -u
```

出てくるのが `169` と `71` だけなら正常。他の値が混ざっていたらファイル名が
変質しているので、コピー方法を見直す（WSL 内で `cp` するのが確実）。

### Elasticsearch とスワップの設定

`vm.max_map_count` は Docker Desktop の WSL2 バックエンドが既定で 262144 を
設定するので、通常は追加設定が要らない（上の `sysctl` は WSL2 では不要）。
確認するなら次のとおり。

```powershell
wsl -d docker-desktop sysctl vm.max_map_count
```

足りない場合や、`memswap_limit` について警告が出る場合は `.wslconfig` に足す。

```ini
[wsl2]
kernelCommandLine = sysctl.vm.max_map_count=262144 swapaccount=1
```

### 16 GB のホストでの回し方

VM に 10 GB しか渡せないので、`.env.docker` で Elasticsearch を絞る。

```bash
ES_JAVA_OPTS=-Xms1g -Xmx1g
ES_MEM_LIMIT=2g
```

WSL2 では VM 自体（カーネル + Docker Desktop）が 1〜1.5 GB 使うので、10 GB の
割り当てのうちコンテナに回せるのは 8.5 GB ほど。段ごとの積み上げは次のとおり
（モデルを読む前の起動直後を「待機」とした。noir と violet がモデルを抱えた
ままの待機は 5.3 GB）。

| 段 | 内訳 | 合計 |
| --- | --- | --- |
| 待機 | ES 0.8 + queen 0.4 + 小物8つ 0.7 | 1.9 GB |
| crow → queen | 変わらず | 2.0 GB |
| noir | + 0.7 | 2.6 GB |
| **violet** | **+ 4.0（CLIP のロード時ピーク）** | **5.9 GB** |
| violet 終了後 | violet 2.7 を抱えたまま | 5.3 GB |
| cendrillon → panther | + 0.1（cendrillon は 90 MB ほど） | 5.4 GB |

**一番きついのは violet が CLIP を読む瞬間**で、ここは削れない（violet は joker の
画像セマンティック検索で CLIP のテキストタワーを使うため）。8.5 GB に対して
2.5 GB 残るので、**navi の「パイプライン開始」（一括実行）で通る**。

cendrillon の段でモデルが増えないのは、cendrillon が noir / violet の API を
叩いて計算してもらっているため。以前は cendrillon も自前でモデルを読んでいて
3つ分が重なり、1段ずつ回して途中で noir / violet を再起動する必要があった。
その代わり、**cendrillon の段では noir と violet を落とせない**。

なお violet が並列ワーカーで動いているあいだ、CLIP を読んでいるのは
ワーカープロセスのほうで、親プロセスは空のままのことがある。その場合
cendrillon の最初の1枚で親が CLIP（両タワー）を読むので、上の表の 2.7 GB は
violet の段ではなく cendrillon の段で乗る。合計は変わらず、`VIOLET_MEM_LIMIT`
の 6 GB がロード時ピークを見込んだ値なのも変わらない。

それでも足りない場合（ES を `-Xms2g` に戻したい、他のコンテナも同居している等）は、
サービスカードの「開始」で1段ずつ回す。

コマンドで回す場合は、nginx 経由（`PHANTOM_HTTP_PORT`、既定 8080）で navi の
API を叩く。前の段が終わってから次を投げること。

```bash
curl -X POST localhost:8080/api/services/cendrillon/start -H 'content-type: application/json' -d '{"params": {}}'
```

```bash
curl -s localhost:8080/api/services | python3 -m json.tool | grep -A3 '"name": "cendrillon"'
```

メモリ上限に当たって落ちていないかは次で確認できる。

```bash
docker inspect --format '{{.Name}} OOMKilled={{.State.OOMKilled}}' $(docker compose --env-file .env.docker ps -q)
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
# 展開先（crow / queen / noir / violet / cendrillon が書き、mona / panther が読む）
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
| `PHANTOM_HTML_SRC_DIR` | XML が無く HTML + 画像しか残っていない文書の場所（cendrillon 用・read-only）。無ければ `PHANTOM_SRC_DIR` と同じでよい |
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

crow / cendrillon は `infra/whitelist/white-list.json` を起動時に読み、そこに
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
| `es-data` | Elasticsearch のインデックス | 任意（パイプライン再実行で再生成できる） |
| `crow-state` / `queen-state` / `noir-state` / `violet-state` / `cendrillon-state` / `panther-state` | タスクの進捗・履歴 | 不要 |
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
