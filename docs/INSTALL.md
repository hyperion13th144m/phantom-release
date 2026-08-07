# インストール

phantom-release を使って、全文検索システムを実行するための手順です。Docker が動作する Linux 環境を想定しています。

## 動作環境

動作確認している環境例:

- CPU: AMD Ryzen 3 4300G
- Memory: 32GB
- Storage: 1TB SSD、HDD 100GB 以上
- OS: Ubuntu 24.04 LTS
- 必要ソフトウェア: git、Docker 28

Docker が動作すれば、Docker Desktop for Windows でも動く可能性があります。

データ容量の目安:

- 全文検索システム本体: 約 5GB
- 特許願 4,500 件程度、その他文書 15,000 件程度: 約 13GB

## Docker のインストール

公式手順を確認してください。

[Docker Engine install documentation](https://docs.docker.com/engine/install/ubuntu/)

Ubuntu の例:公式サイトより引用

```bash
sudo apt update
sudo apt install ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
```

```bash
sudo tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

sudo apt update
sudo apt install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

一般ユーザーで Docker を使う場合:

```bash
sudo usermod -aG docker $USER
```

ログインしなおして確認します。

```bash
docker run hello-world
```

## git のインストール

```bash
sudo apt update
sudo apt install -y git
```

## phantom-release の取得

全文検索システムは一般ユーザーで動作します。100GB 以上の空き容量があるディレクトリを推奨します。

```bash
cd /home/hoge
git clone https://github.com/hyperion13th144m/phantom-release -b vx.y.z
cd phantom-release
```

`-b vx.y.z` は利用するバージョン番号です。古いバージョンは動作しない場合があります。GitHub のリリースページで最新バージョンを確認してください。

## インターネット出願ソフトのデータの準備

インターネット出願ソフトのデータを、全文検索システムから読めるようにします。SSH、SFTP、Samba経由でLinuxにコピーする、インターネット出願ソフトのデータフォルダを共有し、LinuxからそれをRead onlyでマウントするなど方法は任意です。

以下の説明では、インターネット出願ソフトのデータが `/src` に見えているものとします。

```bash
find /src
/src/ITAK.JP0/APPL.JP1/利用者１.J01/ACCEPT.J04/209910417411209420_A163_____X123412340__123457891_____AAA.JWX
...
```

インターネット出願ソフトは、デフォルトだと C:\JPODATA` にデータが格納されている。そのディレクトリ内容が全文検索システム側から `/src` として見えれば OK です。

## 設定

設定ファイルをコピーして編集します。

```bash
cp env.sample .env
vi .env
```

最低限、`SRC_DIR` にインターネット出願ソフトのデータディレクトリを設定します。

```dotenv
SRC_DIR=/src
NGINX_PORT=8080
```

その他は基本的に変更不要です。必要に応じて Elasticsearch やログディレクトリの設定を調整してください。

主要な項目:

```dotenv
### please set path to src directory ###
SRC_DIR=/path/to/src

### change as you like
NGINX_PORT=8080

### do not change below values
DATA_DIR=./var/data
EXTRA_DATA_DIR=./var/extra-data
LOG_DIR_CROW=./var/log/crow
LOG_DIR_MONA=./var/log/mona
LOG_DIR_NAVI=./var/log/navi
LOG_DIR_VIOLET=./var/log/violet
LOG_DIR_FOX=./var/log/fox
LOG_DIR_PANTHER=./var/log/panther
LOG_DIR_JOKER=./var/log/joker
LOG_DIR_SKULL=./var/log/skull
LOG_DIR_NOIR=./var/log/noir
SQLITE_NAME=extra-data.sqlite3

NAVI_ORCHESTRATION_WEBHOOK_SECRET=1234567890abcdef
NAVI_ORCHESTRATION_WEBHOOK_TIMEOUT_SECONDS=5

ES_USER=elastic
ES_PASSWORD=elastic
ES_INDEX=patent-documents
ES_IMAGE_INDEX=patent-images
ES_CHUNK_SIZE=100
ES_REQUEST_TIMEOUT=120

# Elasticsearch の JVM ヒープサイズの上限。必要に応じて調整してください。
MEM_LIMIT=1073741824

# Elasticsearch の JVM オプション。必要に応じて調整してください。
ES_JAVA_OPTS=-Xms512m -Xmx512m
```

## イメージのダウンロード,ビルド

```bash
./scripts/install.sh
```

システムを動作させるための Docker image をダウンロードします。約 5GB 程度です。手元でビルドするサービスもあるので少々時間を要します。

## 起動

```bash
./scripts/service.sh start
```

`start.sh` は次を実行します。
- データやログを保存するディレクトリの作成
- 各種サービスを起動
- Elasticsearch の起動完了を待って index 作成

ブラウザで次の URL にアクセスします。

```text
http://192.168.1.1:8080
```

`192.168.1.1` は全文検索システムを起動しているコンピュータの IP アドレス、`8080` は `.env` の `NGINX_PORT` です。


## 停止

```bash
./scripts/service.sh stop
```

## データ取り込み
データ取り込み操作は、管理画面の `Crow の管理画面へ` から行います。詳細は [データ収集・登録・復旧](docs/OPERATION.md) を参照してください。
