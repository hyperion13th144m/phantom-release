# Windows ネイティブ対応と ETL 新ループ 設計書（Python 版）

状態: §3 の 1〜10 を実装済み（2026-10-19）。書き始めたときは 2026-10-18 時点の develop（`339920c`）が前提。
[rust-migration-design.md](rust-migration-design.md) の代わりになる案で、Python と Node のまま進める。

## 0. 結論

| 論点 | 結論 |
| --- | --- |
| 進め方 | **① 今の構成のまま Windows で動かしてみて、問題を直す → ② 新ループに作り替える**の2段階。①で直したものは②にそのまま引き継ぐ |
| 新ループ | ETL を **navi の中に移す**。1文書ずつ「展開 → 変換 → 書誌 → 画像 → ES 登録」と最後まで流し、終わった文書から検索に出るようにする。数件の文書をスレッドで同時に流して、CPU を遊ばせない |
| モデル | **常駐するモデルサーバー `lavenza` を1つ作る**（noir と violet のモデル部分をまとめたもの）。navi の ETL と joker の検索の両方がこれを使う。navi 自身は torch を持たない |
| OCR | navi の中で tesseract を呼ぶ（モデルではなく外部プログラムの起動なので、モデルサーバーに置く理由がない） |
| サービス | crow・queen・noir・violet・cendrillon・panther は**コードを navi と lavenza に移して廃止**。常駐するプロセスは 11 → **6**（navi・lavenza・mona・skull・fox・joker）に減る |
| skull | Python のまま。Python を残すと決めたので、移行する理由がなくなった |

### 前提（2026-10-18 にユーザーから）

| 項目 | 値 | 設計への効き方 |
| --- | --- | --- |
| Windows 機 | Intel Core i5-9400F（**6コア6スレッド、SMT なし**、内蔵 GPU なし）、メモリ 32 GB | 物理コア＝論理コア＝6 なので、「SMT まで使うと torch が激遅」の罠は起きない。そのぶん、OCR・torch・Pillow がすべて同じ6コアを取り合うので、配分を明示的に決める（§2.4）。メモリには余裕がある（§2.9） |
| 元データ | **ネットワークドライブから直接**読む。**約 700 件**（当初 2,300 件としていたのは覚え違い。2026-10-19 に実数を確認） | 件数が少ないので、毎回全件のハッシュを計算しても数十秒〜数分で済む見込み。スキャンのキャッシュ（§2.5）は初期の作業範囲から外す |
| 動かし方 | **Windows にログオンしている間だけ**動けばよい | Windows サービス化は不要。タスクスケジューラの「ログオン時」に launcher を登録する（§1.3） |
| 基本の運用 | Linux + Docker。Windows ネイティブはもう一つの選択肢 | どちらでも同じコードで動くことを完了条件にする |

各サービスにはすでに `process_document(doc_dir, …) -> ItemResult` という**1文書単位の処理関数**があり、処理済みならスキップする作りになっている。モデルや OCR も関数の引数で渡しているので、HTTP 越しの呼び出しに差し替えられる。そのため新ループの中心は**書き直しではなく、既存の関数の組み合わせ直し**になる。

## 1. 第1段階: 今の構成で Windows ネイティブ動作確認

### 1.1 コードを読んで分かったこと

問題がなさそうなもの（実機で確かめる）:

- saxonche 13.0.0 と torch 2.13.0+cpu は、uv.lock に Windows 用（win_amd64）のパッケージが入っている
- queen と violet のプロセスプールで渡している関数はモジュールのトップレベルにあり、Windows の起動方式（spawn）でも子プロセスに渡せる
- テキストファイルの `open()` はすべて `encoding=` を指定している（Windows の既定は cp932 なので重要）
- 日時は `timezone(timedelta(hours=9))` の固定オフセット。Windows では `TZ` 環境変数が効かず、`ZoneInfo` にも tzdata が要るが、そのどちらも使っていない
- cendrillon のファイル名のバイト長は「str を cp932 に変換してから数える」ので、NTFS の UTF-16 から読んでも同じ結果になる。WSL 経由でファイル名が化ける問題（production.md に記載）は、むしろ解消する

直す必要があるもの:

| # | 問題 | 場所 | 対処 | 実機（2026-10-19） |
| --- | --- | --- | --- | --- |
| W1 | 既定のパスが Linux 前提（`/var/lib/<svc>/tasks`、`/infra/es`、`sqlite:////var/lib/skull/skull.db`、XSL の `/libs/jpo-schema`） | 各 `config.py` | `PHANTOM_HOME` 環境変数を足し、既定のパスはその下にする（未指定なら、Linux は従来どおり、Windows は `%LOCALAPPDATA%\phantom`）。Docker では今の値を明示的に渡すので挙動は変わらない | 問題なし（`PHANTOM_HOME` の下にタスク状態と skull の DB ができた。XSL と ES のマッピングも自動で見つかった） |
| W2 | `.env` の読み込みを direnv / `source .env` でやっている | docs/development.md | `uv run --env-file .env …` に統一する（Windows でも同じ書き方で使える）。Windows 用には `.env.windows.sample` を用意する | 問題なし。ただし `.env` は compose 用（`PHANTOM_*`）と別物なので、`.env.windows.sample` から作ること |
| W3 | tesseract が PATH に入らない（UB Mannheim のインストーラーは既定で PATH に追加しない） | violet `ocr.py` | 環境変数 `TESSERACT_CMD` を `pytesseract.tesseract_cmd` に渡す。日本語の言語データ（jpn）はインストーラーで選ぶよう手順書に書く | 問題なし。学習データの差は W15 |
| W4 | ログをファイルに書き出すと cp932 で書かれ、cp932 に無い文字で `UnicodeEncodeError` になる | 全サービス | `PYTHONUTF8=1` を起動スクリプトで必ず設定する | 問題なし |
| W5 | `open(..., "w")` が改行を CRLF に変えるので、Linux で作った JSON とバイト単位で一致しなくなる | json を書く箇所すべて | `newline="\n"` を付ける。ファイルの書き出しを共通関数（`docstore.write_json`）にまとめるときに一緒に直す。panther の「登録済み判定」は JSON を読み込んで比較しているので、ここは影響を受けない | JSON は LF になった。漏れがあった → W12・W13 |
| W6 | Docker Compose が無いので、11 個のプロセスを起動・停止・再起動する手段が無い | — | §1.3 | launcher で 11 個とも起動・自動再起動・Ctrl+C での停止を確認 |
| W7 | Docker の `mem_limit` による OOM 保護が無くなる | — | ワーカー数の既定値を抑え、手順書にメモリの目安を書く。新ループに移るとプロセスが減るので、ある程度は自然に解決する | 実測した（windows-native.md §6）。待機中は phantom の 11 プロセスで約 1.1 GB ＋ ES 4.6 GB。全件の取り込み中は合計 18.0 GB まで増え、うち violet が 10.6 GB（R5）。32 GB の機械では落ちなかった。ワーカー数と ES ヒープを絞れば 9.6 GB で、16 GB の機械でも動く見込み |
| W8 | `requires-python >=3.12` なのに、コードは 3.14 でしか動かない（`os.process_cpu_count`、PEP 649 前提の注釈）。uv が 3.12 を選び、queen・violet・cendrillon が起動しなかった | pyproject・uv.lock | `.python-version`=3.14、`requires-python >=3.14`（Docker はもともと 3.14） | 直した |
| W9 | Git for Windows の既定（`core.autocrlf=true`）で作業ツリーが CRLF になる | — | `.gitattributes`（`* text=auto eol=lf`） | 直した |
| W10 | fox を base `/` でビルドすると、nginx の `/fox/` 配下が 404 | windows-native.md | `FOX_BASE_PATH=/fox` を付けてビルドする | 直した（手順書） |
| W11 | `FOX_URL` を navi（health の確認先）と joker（リンク先）が別の意味で使う。compose ではコンテナごとに渡せたが、1つの `.env` では衝突する。サービスの既定の URL の `localhost` も、Windows では `::1` に解決されることがある | `.env.windows.sample`・launcher のひな形 | URL はすべて `127.0.0.1` で書き、joker の `FOX_URL` は launcher の設定で joker にだけ渡す | 直した |
| W12 | `ElementTree.write` にパスを渡すとテキストモードで開くので、Windows では XML が CRLF になる | queen `jpoxml/merge.py`（`all.xml`）、libefiling `charset.py`・`manifest.py` | バイナリで開いて書く / `newline="
"` | 直した（queen、libefiling 0.3.1） |
| W13 | libefiling が raw の XML と画像を glob の順のまま manifest に並べる（ext4 はハッシュ順、NTFS は名前順） | libefiling `parse.py`・`manifest.py` | ファイル名で並べる | 直した（libefiling 0.3.1、crow の依存を `>=0.3.1` に）。Linux でも 0.3.1 で作り直し、manifest が一致することを確認した |
| W14 | ES 9 は設定が無いと HTTPS と自動生成のパスワードを有効にする | ES の `elasticsearch.yml` | compose と同じ `single-node`・`xpack.security.enabled: false`、`network.host: 127.0.0.1` | 手順書に記載 |
| W15 | UB Mannheim の jpn 学習データが Linux（tessdata_fast 4.1.0）と別物で、OCR の結果が大きく違う（遅さも約 2 倍） | `.env` | violet のイメージから取り出した学習データを `TESSDATA_PREFIX` で指す | 学習データはそろえた（平均 0.68 → 0.96）。5.5.0 にしても残りの差は消えない。同じ機械の Linux 版では一致するので、Windows 版のビルドの違い（既知の差として扱う） |

実機で確かめるまで分からないもの（リスクの高い順）:

| # | 確認すること | 起きそうなこと | 実機（2026-10-19） |
| --- | --- | --- | --- |
| R1 | Windows Defender のリアルタイムスキャン | 文書ストアに小さいファイルを大量に書くので、極端に遅くなる。ファイルの rename や削除がスキャン中のロックで `PermissionError` になることもある。**データディレクトリと元データをスキャン対象から除外する**のが手順の前提になりそう | 除外なしでも rename・削除の失敗は起きなかった。性能は除外の前後で測る（前: queen 10.1・noir 30.2・violet 77.0 秒、後: 9.3・30.9・80.9 秒。この規模ではほぼ変わらない） |
| R2 | ネットワークドライブ | ログオン中のユーザーとして動かすので、ドライブレター（`Z:` など）も見える。ただしログオン直後は、割り当てたドライブの再接続が遅れることがある（エクスプローラーで開くまで「切断」のまま、など）。launcher がログオン時に起動した直後の取り込みで見えない可能性があるので、**UNC パス（`\\server\share`）で指定する**のを既定にする。共有に到達できないときは、scan がエラーにして実行全体を failed にする（「0 件だった」と区別するため） | UNC で問題なし。約 690 件の全件スキャンとハッシュが 54.6 秒。共有に作業用のフォルダがあると crow がそれも拾う |
| R3 | パスの長さ（260 文字の上限） | HTML のファイル名は cp932 で 169 バイト（全角で 80〜100 文字程度）あり、共有フォルダの深い場所にあると上限を超えうる。Windows の LongPathsEnabled をオンにすれば Python は長いパスを扱える。手順書に載せ、§1.2 で実データの最長パスを測る | 元データの最長 119 文字、HTML 210 文字、文書ストア 160 文字。cendrillon の判定も通った |
| R4 | ファイルのロック | Windows では開いているファイルを rename・削除できない。crow が失敗時に `shutil.rmtree` で後片付けをするとき、Defender や mona がファイルを開いていると失敗する。失敗しても致命的にはしない（ログに残して次回の実行でやり直す） | 起きなかった |
| R5 | spawn によるワーカー起動の速さとメモリ | spawn は子プロセスごとにモジュールを読み込み直す。violet のワーカーが CLIP を読む時間とメモリが、fork のときより増える可能性がある。新ループで OCR を navi に移すと、この問題自体がなくなる | 速さは問題なし。**メモリは予想どおり増えた**: violet の画像のワーカー 4 つがそれぞれ CLIP を読み、コミット済みのプライベートが合計 10.6 GB（compose の violet の上限は 6g）。lavenza にまとめれば解決する（§2.2）。それまでは `VIOLET_IMAGE_WORKERS=1`・`QUEEN_IMAGE_WORKERS=2`・ES ヒープ 2 GB で、ピークを 18.0 → 9.6 GB に抑えられる（時間は 683 → 1,032 秒、出力は同じ） |
| R6 | Windows での torch のスレッドの挙動 | i5-9400F には SMT が無いので、SMT の罠そのものは起きない。それでも、6 スレッド全部を torch に渡すと tesseract と取り合いになる。最適な配分は §2.4 で測る | noir は torch の既定（6 スレッド）、violet はワーカーごとに 1 スレッドで、Linux とほぼ同じ時間。配分は §2.4 で測る |
| R7 | Elasticsearch の Windows 版 | zip 版に `analysis-icu` と `analysis-kuromoji` を `elasticsearch-plugin install` で入れる。メモリ（`-Xmx`）を `jvm.options.d` で指定する | zip 版 9.5.4 ＋ プラグイン2つで動いた。設定は W14 |
| R8 | nginx の Windows 版 | 上流のサービスを Docker のサービス名ではなく `127.0.0.1:port` で指す、Windows 用の設定ファイルが要る | `infra/nginx/nginx.windows.conf` を作った。WSL の phantom が 8080 をつかんでいると起動しない |

### 1.2 動作確認の手順

Windows の実機で、上から順に確かめる。それぞれの結果（かかった時間、エラー）を記録して §1.1 の表を更新する。

1. **環境構築**: uv、Node（LTS）、tesseract（jpn 付き）、Elasticsearch（プラグイン2つ）、nginx を入れる → `uv sync --all-packages` が通るか
2. **単体テスト**: `uv run --package <svc> pytest services/<svc>/tests` を全サービスで実行する。パス区切り、改行コード、文字コードに起因する失敗をここで洗い出す
3. **小規模の E2E**: テストデータ（`phantom-test-data/src`、約 60 ファイル）を **UNC パスで**指定し、navi のパイプライン一括実行を最後まで流す → joker で検索 → fox で表示
4. **同一性の確認**: 同じ入力で Linux（Docker）が作った文書ストアと突き合わせる。`document.json`・`document-properties.json`（ベクトル以外）・`images-information.json`・`images-properties.json` の ocrText は**一致するはず**。ベクトルはコサイン類似度で比べる（torch が同じ版でも、CPU 命令の違いで小さな差は出る）。比べるためのスクリプトは `scripts/diff-store.py` として作る
5. **性能**: 実データ 25 文書で、queen・noir・violet のかかった時間を、2026-08-11 に Linux の開発機で測った値（queen 9.6 秒・noir 23.9 秒・violet 69.9 秒）と比べる。Defender を除外する前と後の両方を測る
6. **長いパス・HTML**: 実データの中で最も長いパスを測る。cendrillon の取り込みを流して、ファイル名のバイト長の判定（169 / 71）が通るか確かめる
7. **ネットワークドライブの読み込み速度**: 元データ（約 700 件）を、UNC パスで全件スキャンし、XML の SHA-256 を計算するのにかかる時間を測る（処理済みの文書を再実行したときの時間の目安になる。§2.5）

### 1.3 プロセスの起動管理（W6）

第1段階ではプロセスが 11 個あるので、**`phantom-launcher`**（小さな Python パッケージ、`scripts/launcher` あたり）を作る。

- 起動するコマンドの一覧を TOML で書く（`uv run --env-file .env navi` や `npm --prefix services/fox start` など）
- 子プロセスを起動し、落ちたら一定の間隔をおいて再起動する（compose の `restart: unless-stopped` の代わり）
- 標準出力と標準エラーをサービスごとのログファイルに書き出す（日ごとに切り替え）
- Ctrl+C で子プロセスをまとめて止める（Windows ではシグナルが届かないので、`CTRL_BREAK_EVENT` と、それでも止まらなければ `terminate()`）
- Windows にログオンしたとき自動で立ち上がるよう、タスクスケジューラに `phantom-launcher up` を登録する（トリガーは「ログオン時」、「ユーザーがログオンしているときのみ実行する」）。ログオン中だけ動けばよいので、Windows サービス化はしない
- コンソール画面を出さずに動かすため、タスクスケジューラからは launcher の gui-scripts 版（`.venv\Scripts\phantom-launcherw.exe up`）を起動する。2026-10-19 に実機で、ログオン時の起動と `down` での停止を確認した（設定は [windows-native.md](windows-native.md) §4）
- 定期的な取り込みも、同じタスクスケジューラに `curl.exe -X POST http://localhost:8005/api/runs` を登録する。ログオンしていない時間は実行されないが、それで問題ない

第2段階でプロセスが 6 個に減っても、この起動の仕組みはそのまま使える。

## 2. 第2段階: 新ループ

### 2.1 構成

```
                ┌───────────── navi ─────────────────────────────┐
cron / タスクスケジューラ │ 管理 UI・実行 API                                  │
 POST /api/runs ─┤ Runner ── 文書スレッド × N                              │
                │   scan(xml) ┐   展開 → 変換 → 書誌 → 画像 → ES 登録 ──┼──→ Elasticsearch
                │   scan(html)┘     │      │      │      │               │
                │                   │   画像変換用の  │   OCR（tesseract を │
                │                   │   プロセスプール │   セマフォで数を制限）│
                └───────────────────┼─────────────────┼─────────────────┘
                                    │  テキスト・画像のエンベディング（HTTP）
                ┌─────── lavenza ────▼─────────────────────────────┐
                │ ruri-v3（文書・クエリ）＋ CLIP（画像・テキスト）を常駐 │ ←── joker（検索クエリ）
                └──────────────────────────────────────────────────┘
mona（読み取り専用の配信）← fox / joker      skull      fox / joker（Node）
```

### 2.2 モデルを常駐させる場所: lavenza（noir と violet のモデル部分をまとめたもの）

> 2026-10-19 に、§3 の 10 で殻の queen を消したあと、lavenza を **queen** に改名した（ポート 8001、環境変数 `QUEEN_*`、
> HF キャッシュの目印 `queen-models.json`）。この節と §3 の記録は、改名する前の名前のまま残している。

navi の中に置かずに、別のプロセスとして常駐させる。理由:

1. **joker の検索はモデルを常に必要とする。** navi の再起動中や ETL の不具合で検索まで止まると困る
2. **navi を軽く保てる。** torch と CLIP（常駐 2.7 GB、読み込み時のピーク 4 GB）を抱えたプロセスと ETL を分けておけば、メモリ不足で落ちたときに影響が片方で済む
3. **実績がある。** cendrillon がすでに「モデルは HTTP で借りる」形で動いていて、ベクトルが元の実装とビット単位で一致することも確認済み（2026-08-12）
4. **HTTP の手間はほぼ無視できる。** テキストのエンベディングは約 1 秒/文書、画像は約 0.2 秒/枚かかるので、HTTP の数ミリ秒は誤差の範囲。画像は今の cendrillon と同じく `{docId, filename}` だけを送り、lavenza が文書ストアから読む（同じホストで動かすのが前提）

noir と violet を **1つのプロセスにまとめる**のは、Windows で起動するプロセスを減らすため。torch のスレッドプールが2つのプロセスで別々にコアを取り合うのも防げる（Linux の開発機 Ryzen 3 4300G では、取り合いが SMT の罠と重なってさらに遅くなる）。

lavenza の API（既定のポートは 8009。パスはモデルごとに分けて今の形を残す）:

| パス | 中身 | 今の場所 |
| --- | --- | --- |
| `POST /noir/embeddings/query` | ruri のクエリ埋め込み | noir `/embeddings/query` |
| `POST /noir/embeddings/document` | ruri の文書埋め込み | noir `/embeddings/document` |
| `POST /violet/embeddings/query` | CLIP のテキスト埋め込み | violet `/embeddings/query` |
| `POST /violet/embeddings/image` | CLIP の画像埋め込み（`{docId, filename}`） | violet `/embeddings/image` |
| `GET /health` | | |

呼ぶ側（noir・violet・cendrillon・joker・navi）は `LAVENZA_URL`（既定 `http://localhost:8009`）で lavenza を指す。
当初は joker の `NOIR_URL` / `VIOLET_URL` を lavenza に向けるだけのつもりだったが、同じ変数名を navi が
noir・violet のタスクの呼び先として使っていて、1つの `.env` を共有する Windows ネイティブでは衝突するので、
新しい変数にした（2026-10-19。ポートも、noir が 8004 を使い続けるあいだは重ならないよう 8009 にした）。

- 推論はモデルごとにロックをかけて1件ずつ実行する。torch のスレッド数は物理コア数（今の既定のまま）
- ETL が大量にリクエストを送っている間も検索が待たされすぎないよう、ロックの順番待ちでは**クエリを優先する**（優先度付きのロック。中身は条件変数と、待っているクエリの数を数えるカウンタ）
- モデルは最初に呼ばれたときに読み込む。CLIP の画像側とテキスト側は、今の violet と同じように片方ずつ読み込めるようにしておく
- 名前はペルソナ5ロイヤルのラヴェンツァから取った。ベルベットルームの住人で、ジョーカー（joker）が持ち込んだものを、ペルソナという「別の形」に変える手伝いをする。文書や画像をベクトルという別の形に変えて、ETL（navi）と検索（joker）の両方を裏で支える、この役割に合わせた。候補として考えた oracle は、双葉の英語版のコードネームで、日本語版では「ナビ」になる。つまり navi と同じ人物を指してしまうので避けた

### 2.3 文書1件の処理の流れ

XML 由来の文書:

| 段 | 今の関数 | 新ループでの扱い | 処理済みの目印 |
| --- | --- | --- | --- |
| extract | `crow.pipeline.ingest_document` | 「出力先がある → 文書全体をスキップ」から、**「展開だけスキップして次の段へ進む」**に意味を変える | 文書ディレクトリ（§2.5 で原子的に作るよう直す） |
| convert | `queen.pipeline.process_document` | そのまま。画像変換のプロセスプールは、実行1回につき1つを全文書スレッドで共有する | `json/document.json` |
| properties | `noir.pipeline.process_document` | provider に lavenza を呼ぶ実装（`RemoteEmbeddingProvider`）を渡す | `json/document-properties.json` |
| images | `violet.pipeline.process_document` | `ocr_image` には navi の中で tesseract を呼ぶ関数を、`embed_image` には lavenza を呼ぶ関数を渡す。violet のワーカープールは使わない | `json/images-properties.json` |
| upload | `panther.pipeline.process_document` | そのまま | `json/doc.json`・`img.json` |

HTML 由来の文書: `cendrillon.pipeline.ingest_document`（Enricher の向き先を lavenza にして、OCR は navi の中で行う）→ upload。

**ある段が失敗したら、その文書の処理はそこで打ち切る**（後ろの段は処理済みの目印が揃わないので、どのみち進めない）。失敗した段と、traceback の要約を記録する。次回の実行では、目印の無い段からやり直しになる。

### 2.4 並列化

Python なので、段ごとにキューを並べるパイプラインは作らず、**「N 本の文書スレッドが、それぞれ1文書を最初から最後まで処理する」**単純な形にする。重い処理はどれも GIL の外で動くので、スレッドで十分に重なる。

| 重い処理 | GIL の外で動く理由 | 同時に動かす数の制御 |
| --- | --- | --- |
| 画像変換（Pillow） | プロセスプール | プールのサイズ（`NAVI_IMAGE_WORKERS`） |
| XSLT（saxonche） | ネイティブのコード。今の queen と同じく、ロックをかけて1件ずつ実行する | ロック（1件） |
| OCR | tesseract という別プロセス | セマフォ（`NAVI_OCR_SLOTS`）、`OMP_THREAD_LIMIT=1` |
| エンベディング | lavenza の中 | lavenza 側のロックと、torch のスレッド数（`LAVENZA_TORCH_THREADS`） |
| ES 登録 | ネットワーク I/O | なし |

- 同時に処理する文書の数は `NAVI_DOC_CONCURRENCY`。これを増やしすぎても、OCR と lavenza が詰まって待ちが増えるだけ

既定値（i5-9400F、6コア・SMT なしの実機で、Windows ネイティブと Docker の両方で測って決めた。§3 の 9）:

| 設定 | 既定値 | 考え方 |
| --- | --- | --- |
| `NAVI_DOC_CONCURRENCY` | 4 | OCR・推論・画像変換が、それぞれ別の文書で同時に動ける数。3 より少し速い |
| `NAVI_OCR_SLOTS` | 4 | 律速になる OCR（約 2.4 秒/枚）。1文書の中の画像も、このスロットの数まで同時に OCR する |
| `LAVENZA_TORCH_THREADS` | 0（torch の既定＝物理コア数） | 減らしても取り込みは速くならなかった。減らすと、取り込んでいないときの検索のクエリが遅くなる |
| `NAVI_IMAGE_WORKERS` | 4 | 画像変換は文書の最初に一瞬だけ発生するので、コアを専有させずに時分割で共有する。2 でも差は小さい |

- 測る前の仮の値は 3・3・3・4 だった（OCR と torch でコアを半分ずつ分ける考え）。測ってみると、CPU はどの組み合わせでもほぼ使い切っていて（Windows で 95〜98%）、組み合わせの差は小さかった。測った結果は §3 の 9 の記録を参照
- 初回の全件取り込みにかかる時間: Windows の実機で今のパイプラインを流すと、ホワイトリストを通った 191 件（元データ約 700 件のうち）で **683 秒（約 11 分、約 3.5 秒/文書）**だった（2026-10-19）。新ループでは同じ全件が **497 秒**（既定値。§3 の 9）。どれだけかかっても、**最初の1件は数十秒で検索に出る**
- 画像変換のプールを1回の実行につき1つにして全スレッドで共有すれば、spawn のたびに子プロセスを起動し直すコスト（R5）もかからない

### 2.5 再実行と冪等性

**スキャンのキャッシュは作らない（初期の作業範囲外）。** 約 700 件なら、毎回ネットワークドライブ上の XML を全部読んで SHA-256 を計算しても、数十秒〜数分の見込み。処理済みの文書は、各段の目印のファイルを確かめるだけ（stat が数回）でスキップされる。

- スキャンには `os.scandir` を使う。Windows ではディレクトリを列挙するときにサイズと更新日時も取れるので、ファイルごとの stat が要らない。ネットワークドライブでは、ここが効く
- §1.2 で「処理済みの全件を再実行したときにかかる時間」を測る（2026-10-19: 約 690 件の列挙とハッシュで 54.6 秒）。定期実行の間隔に対して重すぎたら、そのときに `(path, size, mtime) → doc_id` のキャッシュ（Python 標準の sqlite3）を足す。キャッシュはあくまでキャッシュで、正しい情報は文書ストアに置くという方針は変えない

**展開を原子的にする。** 今の crow は文書ディレクトリに直接展開している。展開の途中でプロセスを強制終了すると、中途半端なディレクトリが残る。そうなると、次回の実行で「展開済み」と判断されてしまう。これを、`{doc_id}.partial` に展開してから rename する形に変える（同じボリューム内なら Windows でも rename は原子的に行われる）。新ループでは「展開済み＝後ろの段に進む」なので、ここを壊れたままにはできない。

### 2.6 中止と、ES への反映

- **中止**: Runner がキャンセル用のイベントを立てる → スキャンが新しい文書を取り出すのをやめる → 各文書スレッドは、段と段の間でイベントを確かめて処理を打ち切る。段の途中では止めない（目印のファイルは最後に書くので、途中で止めた段も次回やり直されて正しく完了する）。OCR の待ち時間が長い場合に備えて、tesseract のプロセスには timeout を付ける
- **ES への反映**: panther は文書1件ごとに bulk で登録している（文書1件と、その画像 N 件をまとめて1回）。まずはこのままで行く。ES の `refresh_interval`（既定 1 秒）が過ぎれば検索に出る。約 700 件なら、1 件ずつ送っても ES の負荷は問題にならない

### 2.7 navi の API と UI

| Method | Path | 説明 |
| --- | --- | --- |
| POST | `/api/runs` | 実行を開始する。`{"sources": ["xml","html"], "maxDocuments": null}` → 202。実行中なら 409 |
| POST | `/api/runs/current/cancel` | 中止する |
| GET | `/api/runs/current` | 実行中の状況（下記） |
| GET | `/api/runs` / `/api/runs/{id}` | 実行の履歴（taskservice の TaskStore を使い回す） |
| GET | `/api/runs/{id}/failures` | 失敗した文書の一覧（doc_id、段、メッセージ。件数に上限あり） |
| GET | `/api/services` | lavenza・mona・fox・joker・skull・ES の health |
| GET | `/health` | |

実行中の状況として返すもの:
- 走査済みの件数
- 段ごとの success / skip / fail の件数
- **検索に出るようになった件数**（upload が成功した件数）
- 処理中の文書と、それぞれが今いる段
- 直近の処理速度（件/分）と、残りの見込み時間

UI は今と同じ静的 HTML で、数秒おきにポーリングする（画面を開いている間だけ）。

cron や Windows のタスクスケジューラからは `curl -X POST http://localhost:8005/api/runs` を叩く（Windows 10 以降は curl.exe が標準で入っている）。Windows はログオン中だけ動けばよいので、タスクスケジューラでも「ユーザーがログオンしているときのみ実行する」にする。

taskservice は「同時に実行するのは1タスクだけ・ジェネレータで1件ずつ結果を返す」という前提のライブラリで、文書を並列に流すのとは形が合わない。そのため、Runner は navi の中に新しく書く。永続化（TaskStore）とモデル（ItemResult など）は使い回す。

### 2.8 コードの置き場所

```
services/navi/src/navi/
  server.py            FastAPI（UI・実行 API・health 監視）
  runner.py            Runner（文書スレッド、セマフォ、中止、進捗カウンタ）
  chain.py             文書1件の段の並び（xml / html）
  scan/                xml.py ← crow.scanner、html.py ← cendrillon.scanner
  stages/
    extract.py         ← crow.pipeline（展開の原子化を追加）
    convert/           ← queen（jpoxml、images）
    properties/        ← noir（properties.py、pipeline）
    images/            ← violet（figures.py、ocr.py、pipeline）
    upload/            ← panther（es.py、normalizer.py、transform.py、pipeline）
    html/              ← cendrillon（html/、render.py、properties.py、images.py）
  lavenza_client.py     ← cendrillon.enrich を一般化（テキスト・画像の埋め込みを lavenza に依頼）
services/lavenza/src/lavenza/
  text.py              ← noir.embeddings
  image.py             ← violet.embeddings
  server.py            推論ロック（クエリ優先）と API
```

- コードは**移動するだけで、書き直さない**。テストも一緒に移す。移す前と後で同じテストが通ることを、移す作業ごとに確かめる
- navi の依存パッケージに torch が入らないようにする（Docker イメージを軽くするため）。テストで `import navi` を一通り実行したあと、`sys.modules` に `torch` が無いことを確かめる
- 移し終わったら crow・queen・noir・violet・cendrillon・panther のディレクトリ、compose の定義、GitHub Actions のビルド設定を削除する

### 2.9 Docker（Linux）と Windows での構成

| | Linux + Docker | Windows ネイティブ |
| --- | --- | --- |
| navi | イメージに tesseract（jpn）と saxonche を入れる。torch は入れない | `uv run --env-file .env navi` |
| lavenza | torch・sentence-transformers・open_clip を入れる | `uv run --env-file .env lavenza` |
| mona・skull・fox・joker | 今のまま | launcher から起動 |
| ES・nginx | compose の中 | ユーザーがインストール |
| 起動管理 | compose | phantom-launcher（§1.3）＋ タスクスケジューラ |

メモリの目安: navi 0.5〜1 GB（Pillow のワーカーと saxon）、lavenza 常駐 3.5 GB 程度（ruri 0.7 ＋ CLIP 2.7）・ピーク 4.5 GB 程度。今の noir 2g ＋ violet 6g ＋ queen 2g ＋ cendrillon 512m より小さくなる見込み。

Windows 機（32 GB）での割り当ての目安: Elasticsearch ヒープ 4 GB（`-Xms4g -Xmx4g`、プロセスとしては 5 GB 程度）＋ lavenza 4.5 GB ＋ navi 1 GB ＋ mona・skull・fox・joker・nginx で 1.5 GB ＝ **約 12 GB**。Windows 本体と、そのほかの作業の分を引いても十分に余る。WSL の `.wslconfig` でメモリの割り当てを調整する作業（production.md）は不要になる。

## 3. 作業の順番

進み具合（2026-10-19）: 1〜3 を実装済み（`scripts/diff-store.py`、W1〜W5、`scripts/launcher`）。
4 は Windows の実機で §1.2 の 1〜4・6・7 を流し、見つかった W8〜W15 を直した（結果は §1.1 の表と
[windows-native.md](windows-native.md) §6）。§1.2 の 1〜7 はすべて流した。Linux も libefiling 0.3.1 で作り直した文書ストアと比べ、OCR テキスト以外は一致した。
OCR だけは Windows 版 tesseract のビルドの違いで Linux と一致しない（W15）。§3 の 4 はこれで完了とする。

§3 の 5（lavenza）は 2026-10-19 に入れた。noir・violet のモデルのコードを `services/lavenza` に移し、noir・violet・cendrillon・joker は
`LAVENZA_URL` で lavenza を呼ぶ（noir・violet は torch を持たなくなった）。compose・CI（`docker-build-lavenza.yml`）・launcher も切り替えた。
Windows の実機で、切り替える前と同じ文書ストアができることを確かめた（diff-store で差分なし。文書のベクトルはビット単位で一致、
画像のベクトルは torch のスレッド数が変わったので末尾のビットだけ違い、コサインは 1.000000）。全件（191 件）の取り込みは
683 → 639 秒、phantom ＋ ES のピークは 18.0 → 10.3 GB（windows-native.md §6）。
Linux（Docker、WSL の中）でも、テストデータで切り替える前と同じ文書ストアができた（差は CPU による OCR の揺れ 4 枚だけ）。
ただし Docker の中から Hugging Face への通信が不安定で、lavenza が最初の依頼でモデルを読むときの更新の確認が数分固まり、
violet の最初の文書がタイムアウト（300 秒）で fail になった。lavenza が起動したら裏でモデルを読み始めるようにした（`LAVENZA_PRELOAD`）が、
それでも WSL の Docker では先読みそのものが 10 分以上かかったので、先読みで一度モデルを全部読めたら、次からは
Hugging Face に問い合わせずに（オフラインで）読むようにした（`lavenza/hfcache.py`）。
直したイメージで Docker でもう一度確かめ、先読みは 17 秒（オフラインの2回目は 13 秒、HF への問い合わせ 0 件）、
パイプラインは fail 0 で 192 秒、文書ストアは切り替える前と同じ（差は OCR の揺れだけ）だった。§3 の 5 はこれで完了とする。

§3 の 6（コードを navi に移す）は 2026-10-19 に、サービスごとに区切って行った。移した先は §2.8 のとおりで、
`navi/scan/{xml,html}.py`、`navi/stages/{extract.py,convert/,properties/,images/,upload/,html/}`。
移すあいだも今のパイプラインを止めないよう、crow〜panther・cendrillon はタスクの API・設定・起動だけの**殻**にして、
navi の stages を呼ぶようにした（§3 の 10 で消す）。テストも一緒に移し、件数は移す前と同じ（navi は 15 → 188 件）。
各サービスの conftest の補助は `navi/tests/*_helpers.py` に分けた（conftest どうしの名前の衝突を避けるため）。
移したときに中身を変えたのは、panther の `es.py` が設定の型として `PantherConfig` を受け取っていたのを、使う7項目だけの
`EsSettings`（Protocol）にしたところだけ（navi が panther に依存しないように）。Windows の実機で、移す前と同じ文書ストアが
できることを確かめた（diff-store で差分なし）。殻になった6サービスと navi のイメージも WSL の Docker でビルドし、
起動に要るものを import できることを確かめた（violet だけは WSL の Docker から Debian のミラーにつながらず apt の段で
止まったので、変更した builder の段までを確かめた。CI では問題なくビルドできるはず）。

§3 の 7（Runner・展開の原子化・実行 API）は 2026-10-19 に入れた（`navi/runner.py`・`navi/runconfig.py`、`/api/runs`）。
今のパイプライン（`/api/pipeline`）と並べて置き、片方が動いているあいだはもう片方を 409 で断る（UI と `/api/services` の
作り替えは §3 の 8）。§2 からの補足:

- 同じ文書（同じ XML / HTML）が元データの2か所にあると、並列に流したときに同じ文書を2本のスレッドが展開してしまうので、
  走査する側で文書IDを計算し、かぶったものは流さない（今の crow も2件目をスキップしていた）
- 段の結果から次に進むかは、展開・HTML の取り込みでは「成功」か「処理済み」（`ALREADY_EXTRACTED` / `ALREADY_INGESTED`）なら
  進み、それ以外のスキップ（ホワイトリストの対象外など）は「対象外」として終える。ほかの段のスキップは「処理済み」として進む
- HTML 由来の文書の OCR は、`Enricher` に navi の中の tesseract（セマフォ付き）を渡して行う。殻の cendrillon は今までどおり violet を呼ぶ
- XSL が見つからなくても navi は起動する（今のパイプラインと UI は動かす）。新しいループを始めたときに失敗にする
- navi のイメージに tesseract（jpn）・XSL・ES のマッピング・対象表を入れ、compose で元データと文書ストアをマウントした。メモリの上限は 2g

Windows の実機で、テストデータ（28 文書）を新しいループで流し、今のパイプラインと同じ文書ストアになることを確かめた
（diff-store で差分なし）。153 秒（今のパイプラインは 150 秒）で、最初の文書は約 4 秒で検索に出た。処理済みのものを流し直すと 3.9 秒。
時間が縮まなかったのは、画像の多い1文書の images の段が最後に1本だけ残ったから（新しいループの images の段は、1文書の中では
OCR を1枚ずつ行う）。§3 の 9 で並列度と合わせて見直す。
main にマージしたイメージで、Docker（WSL の中）でも新しいループを確かめた。テストデータは 138 秒、fail 0 で、Docker の今のパイプラインと
同じ文書ストアになった（diff-store で差分なし）。navi のメモリは 480 MB。最初は ES の準備ができる前に実行を始めて失敗したので、
compose の navi は ES が healthy になってから起動するようにした（新しいループは実行の最初に ES のインデックスを確かめる）。

§3 の 8（UI）は 2026-10-19 に入れた。navi の画面の上から「取り込み」（`/api/runs` の開始・中止・状況・段ごとの件数・処理中の文書）、
「履歴」（行を押すと失敗した文書の一覧）、「サービス」（lavenza・mona・fox・joker・skull・Elasticsearch の health）を並べ、
今のパイプラインの画面はいちばん下にたたんで残した（開いているあいだだけ殻のサービスの状態を取りに行く。§3 の 10 で消す）。
`/api/services` に Elasticsearch の health を足し、`?tasks=0` で殻のサービスのタスクの状態を取らないようにした。
Windows の実機で、画面から取り込みを始めて最後まで流れることを確かめた。

§3 の 9（並列度）は 2026-10-19 に測った。先に、§3 の 7 で見つかった「1文書の中では OCR を1枚ずつ行う」のを直した
（images の段に OCR 用のスレッドプールを渡し、1文書の中の画像も `NAVI_OCR_SLOTS` 個まで同時に OCR する。
HTML 由来の文書の OCR と合わせた上限はセマフォのまま）。これだけでテストデータは 153 → 114 秒になった。
そのうえで、i5-9400F の実機で組み合わせを変えて測った（テストデータ 28 文書、文書ストアと ES のインデックスは毎回空から。
lavenza はモデルを読み終わってから始める）。表は「文書・OCR・torch・画像変換」の順:

| 組み合わせ | Windows ネイティブ | Docker（WSL の中） |
| --- | --- | --- |
| 3・3・3・4（仮の値。Docker は torch 0） | 113.5 秒（5回の中央値、105〜131） | 98 秒（2回、96・100） |
| 4・4・2・4 | 99 秒（4回の中央値、97〜108） | 94.5 秒（2回） |
| 4・4・0（物理コア数）・4 | 101.7 秒（3回の中央値、99〜104） | **90 秒**（2回、88.5・92） |
| 3・5・2・4 | 106 秒（4回の中央値） | 93 秒（2回） |
| 6・6・6（0）・4 | 101 秒（4回の中央値） | 88.5 秒（2回） |

1回だけ測ったもの（Windows）: 3・2・4・4 は 127 秒、2・3・3・4 は 117 秒、3・3・3・2 は 110 秒、4・3・3・4 は 104 秒。

- どの組み合わせでも CPU はほぼ使い切っている（Windows で 94〜98%、Docker で 70〜90%）。OCR のスロットと文書の数を
  3 → 4 にすると少し速くなり、OCR を 2 に減らしたり文書を 2 に減らしたりすると遅くなる
- torch のスレッドを減らしても速くならなかった（物理コア数のままで同じかやや速い）。torch を減らすと検索のクエリも遅くなるので、既定のままにする
- 6・6・6 のように物理コア数まで上げても遅くはならなかったが、速くもならないので 4・4 にした
- 全件（Windows、194 文書）では、仮の値で 504.6 秒、4・4・2・4 で 497.2 秒（今のパイプラインは 639 秒）。全件では差はほとんど無い。
  出力は今のパイプラインと同じ（diff-store で 194 文書とも差分なし）。Docker のテストデータの出力も、§3 の 7 の Docker の結果と同じ
- Docker の測定には、main の navi イメージに変更した2ファイルをマウントして使った。テスト用のプロジェクトの HF キャッシュは
  phantom-release からコピーし、lavenza を `HF_HUB_OFFLINE=1` で動かした（WSL の Docker から Hugging Face に繋がらないため。§3 の 5）
- Docker では、compose の navi が ES の healthy を待って起動しても、その直後の実行が「Elasticsearch に接続できません」で
  失敗することがあった（数十秒後には繋がる）。測定のスクリプトでは navi から ES に ping が通るまで待った
- Linux の開発機（Ryzen 3 4300G）では測っていない（WSL の Docker だけにした。2026-10-19 にユーザーと決めた）

既定値は §2.4 の表のとおり（`NAVI_DOC_CONCURRENCY=4`・`NAVI_OCR_SLOTS=4`・`NAVI_IMAGE_WORKERS=4`、`LAVENZA_TORCH_THREADS` は torch の既定）。

§3 の 10（古いサービスを消す）は 2026-10-19 に、3つに分けて行った。

1. 殻になっていた crow・queen・noir・violet・panther・cendrillon と、その GitHub Actions・compose の定義（タスク状態のボリュームも）・
   launcher の定義を消した。navi からは今のパイプライン（`/api/pipeline`・`/api/services/{name}/start|cancel`）と、たたんであった
   古い画面を消し、`/api/services` は health だけを返すようにした。HTML 由来の文書の OCR は navi の中で行うだけにした
   （violet の `/ocr` を呼ぶ経路を消した）。Windows の実機でテストデータを流し、消す前と同じ文書ストアになることを確かめた
2. lavenza を queen に改名した（パッケージ・イメージ `phantom-queen`・compose のサービス・launcher、ポート 8009 → 8001、
   環境変数 `LAVENZA_*` → `QUEEN_*`、navi の `NAVI_LAVENZA_TIMEOUT` → `NAVI_QUEEN_TIMEOUT`）。HF キャッシュの目印は
   `queen-models.json` にして、lavenza のころの `lavenza-models.json` も読む（Windows の実機で、改名したあとも Hugging Face に
   問い合わせずに読めた）。API のパス（`/noir/...`・`/violet/...`）は変えていない。Windows の実機でテストデータを流し、同じ文書ストアになった
3. ドキュメントを今の構成に合わせた。production.md の「Windows（Docker Desktop + WSL2）の場合」は、windows-native.md を指す
   「Windows の場合」に置き換え、取り込みが分かれていたころからの更新の手順を足した。compose の queen は `HF_HUB_OFFLINE` を
   `.env.docker` から受け取れるようにした（noir・violet のころの HF キャッシュには目印が無く、Hugging Face に繋がりにくい WSL の
   Docker では最初の起動が終わらないことがあるため）

Docker（WSL の中）での確認は、main にマージして CI が作った `phantom-queen`（モデルサーバー）と `phantom-navi` のイメージで、
2026-10-19 に行った。テスト用のプロジェクトは lavenza のころの HF キャッシュ（目印は `lavenza-models.json`）と古いタスク状態の
ボリュームを持ったままだったので、「取り込みが分かれていたころからの更新」も兼ねた（`up -d --remove-orphans`）。

- queen は起動して 28 秒でモデルを2つとも読み終えた。Hugging Face への問い合わせは 0 回（古い目印からオフラインに切り替わった）
- テストデータ（28 文書）は 73 秒で fail 0。§3 の 7 の Docker の結果と同じ文書ストアになった（diff-store で差分なし。ベクトル 344 個のコサインはすべて 1.000000）
- joker・navi の `/api/services`（queen・mona・fox・joker・skull・ES がすべて ok）も nginx 経由で応答した。再起動・OOM は無し。メモリは navi 451 MB、queen 844 MB
- navi から ES に繋がったのは、ES が healthy になってから 24 秒後だった（前からある差。取り込みをすぐ始めると「Elasticsearch に接続できません」で失敗する）。
  そこで、実行の最初に ES に繋がらなければ `NAVI_ES_WAIT_TIMEOUT`（既定 60 秒）まで 2 秒おきに ping をやり直すようにした。
  main のイメージで、ES を再起動して healthy になった直後に実行を始めたところ、navi は約 18 秒待ってから繋がり、
  テストデータは fail 0（92 秒）、文書ストアは上の確認と同じだった（diff-store で差分なし）
  （`EsUploader.prepare`）。上限を過ぎても繋がらなければ、今までどおり実行全体を失敗にする
- 古い目印から読めたときに queen の目印が書かれていなかったので、書くようにした（`hfcache.remember_loaded`）

phantom-release（WSL の本番）は今の構成のまま。新しい構成への切り替えは、リリース（`update-release.yml`）のあとに production.md の「更新」の手順で行う。
W1〜W5 は次のように実装した。

- W1: `taskservice.paths`（`PHANTOM_HOME`、未指定なら Windows は `%LOCALAPPDATA%\phantom`、Linux は従来の `/var/lib`）。panther の `ES_MAPPING_DIR` は queen の XSL と同じくリポジトリの `infra/es` を自動で探す
- W2: `uv run --env-file` と phantom-launcher の `env_file`。`.env.windows.sample` を追加
- W3: `TESSERACT_CMD`
- W4: launcher が子プロセスに `PYTHONUTF8=1` と `PYTHONUNBUFFERED=1` を既定で渡す
- W5: JSON を書く `open()` に `newline="\n"`。`docstore.write_json` に寄せる案は、queen・noir・panther の Dockerfile にも手が入るので見送った。libefiling の `manifest.json` は別リポジトリなので、その修正は W12・W13 で行った
- 新たに分かったこと: fox・joker の `npm start` は POSIX シェルの書き方なので Windows では動かない。launcher からは `node dist/server/entry.mjs` を直接起動する

各ステップの完了条件は「テストデータで、前のステップと同じ文書ストアができる」こと（`scripts/diff-store.py` で確かめる）。

| # | 内容 | 段階 |
| --- | --- | --- |
| 1 | `scripts/diff-store.py`（2つの文書ストアを突き合わせる。JSON はキー順をそろえて比較、ベクトルはコサイン類似度、webp は寸法） | 共通 |
| 2 | W1〜W5 を直す（PHANTOM_HOME、TESSERACT_CMD、改行コード、`.env` の読み込み方、PYTHONUTF8） | 1 |
| 3 | phantom-launcher | 1 |
| 4 | Windows の実機で §1.2 の手順を実行し、R1〜R8 の結果を記録して直す | 1 |
| 5 | lavenza を作る（noir・violet のモデル部分を移動）。まずは今のパイプラインの noir・violet・cendrillon から lavenza を呼ぶ形にして、ベクトルがビット単位で一致するか確かめる | 2 |
| 6 | コードを navi の stages に移す（テストも一緒に） | 2 |
| 7 | Runner・展開の原子化・API を作る | 2 |
| 8 | navi の UI を新しい API に合わせる | 2 |
| 9 | 並列度の既定値を、Linux と Windows の両方の実機で測って決める | 2 |
| 10 | 古いサービスを削除し、compose・CI・ドキュメント（production.md の WSL の節は「Windows ネイティブ」の節に置き換える）を更新する。殻の queen を消したあと、lavenza を queen に改名する（ポートは 8001、環境変数は `LAVENZA_*` → `QUEEN_*`、HF キャッシュの目印は `queen-models.json`。2026-10-19 に決定） | 2 |

5 は、6 以降を待たずに今の構成のまま入れられる。入れた時点で、Windows でも Linux でもモデルを読み込むプロセスが1つになる。

## 4. 決まったこと・残っていること

決まったこと（2026-10-18）: Windows 機のスペック、元データ（ネットワークドライブから直接・約 700 件）、モデルサーバーの名前（lavenza）、Windows ではログオン中だけ動かす。いずれも本文に反映済み（冒頭の「前提」の表）。

残っていること（どれも実機で測って決める）:

1. ~~並列度の既定値~~ → 文書 4・OCR 4・画像変換 4・torch は既定（2026-10-19、§2.4・§3 の 9）
2. ~~処理済みの全件を再実行するのにかかる時間~~ → 54.6 秒（2026-10-19、約 690 件）。スキャンのキャッシュは要らない（§2.5）
3. ~~タスクスケジューラから、コンソール画面を出さずに起動する方法~~ → `phantom-launcherw.exe up`（2026-10-19 に確認、§1.3）
