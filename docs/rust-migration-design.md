# ETL の Rust 化 設計書（草案）

状態: 草案 / 実装なし。2026-10-18 時点のリポジトリ（develop `339920c`）を前提にする。

> **2026-10-18 追記**: Rust 化は見送り、Python のまま Windows ネイティブ対応と新ループを進める方針になった。現行の設計は [python-new-loop-design.md](python-new-loop-design.md)。本書は検討記録として残す。

## 0. 結論

| 論点 | 結論 |
| --- | --- |
| ETL の形 | crow〜panther・cendrillon を **1つの Rust バイナリ `navi` の中のパイプライン**にする。サービス間 HTTP と「ステージごとの全件スキャン」をやめ、**1文書ずつ ES まで流す（新ループ）**。ただしステージはパイプライン並列にして、CPU を遊ばせない |
| モデルの置き場所 | **navi プロセスに常駐**させ、ETL ワーカーと joker 向けクエリ API の両方で共有する。別プロセスにも切り出せるよう `Embedder` trait で抽象化しておく（§5） |
| XSLT 3.0 | Rust ネイティブの実用的な XSLT 3.0 実装は無い。**SaxonC-HE の C/C++ API を FFI で呼ぶ**のが第一案（XSL は無変更、出力をバイト一致で検証できる）。Windows 版 SaxonC が手に入らなければ **XSLT 1.0 + libxslt** に落とす（§4.2） |
| OCR | Rust で tesseract 相当を書くのは非現実的。**tesseract 実行ファイルを子プロセスで呼ぶ**（pytesseract も中身はこれ）。Windows では UB Mannheim 版をユーザーがインストール |
| 画像処理 | Rust で可能。G4 TIFF のデコードだけ要検証（§4.3） |
| エンベディング | Rust で可能。モデルを一度だけ ONNX に書き出し、**ort（ONNX Runtime）+ tokenizers** で推論 |
| libefiling | 約1000行。zip・CMS(ASN.1)・MIME・cp932 で、いずれも Rust クレートがある。移植は素直 |
| skull | **Node（Astro）化を推奨**。将来の特許管理 UI の受け皿になるため（§7） |
| mona | Python なので残せない。**同じ Rust バイナリのサブコマンド**にする（複製配置の方針を崩さないため別プロセスで起動） |

**正直な見積もり**: 処理時間の大半は OCR（tesseract、C++）とモデル推論（torch、C++）で、どちらも今すでにネイティブコードが動いている。Rust に書き換えても**ここは速くならない**。速くなるのは次の3点だけ:

1. ONNX Runtime のグラフ最適化（torch eager 比でおおむね 1.2〜2 倍程度が相場。要実測）
2. ステージのパイプライン並列（OCR 待ちの間に別文書の XSLT・画像変換・埋め込みを進める）
3. 再実行時のスキャン短縮（後述の状態 DB で「ハッシュ計算済み・処理済み」を覚える）

「最初の1件が検索に出るまでの時間」は新ループで数時間→数秒に縮むが、これは言語ではなくループ構造の効果。

## 1. 現状

```
crow ─┐                                              ┌─ joker (Node) ── noir /embeddings/query
      ├→ 文書ストア ─→ queen → noir → violet → panther → ES        └─ violet /embeddings/query
cendrillon ─┘   (各ステージが全件スキャン)          ↑
  └─ noir/violet の API を呼ぶ                       navi が HTTP で順番に起動・ポーリング
mona (文書ストアの配信) ← fox / joker
skull (メタ情報, SQLite + ES)
```

| サービス | 中身 | 主依存 | Rust 化後 |
| --- | --- | --- | --- |
| crow | アーカイブ検出・展開 | libefiling | navi の `extract` ステージ |
| queen | XML マージ + XSLT → document.json、画像 → webp | saxonche, Pillow | `transform` / `images` ステージ |
| noir | 書誌・本文抽出、テキスト埋め込み、クエリ埋め込み API | sentence-transformers | `properties` / `embed-text` ステージ + クエリ API |
| violet | 図情報、OCR、画像埋め込み、クエリ埋め込み API | open_clip, pytesseract | `ocr` / `embed-image` ステージ + クエリ API |
| cendrillon | HTML 系の一気通貫取り込み | Pillow, httpx | HTML 系の `extract` / `transform` ステージ（下流は共通） |
| panther | doc.json / img.json 生成、ES 登録 | elasticsearch-py | `upload` ステージ |
| navi | 管制 UI | FastAPI | ETL 本体 + 管理 UI + 制御 API |
| mona | 静的配信 | FastAPI | `phantom mona`（同一バイナリ別プロセス） |
| skull | メタ情報 CRUD・ES 同期 | FastAPI, SQLAlchemy | Node（推奨）または Rust |
| fox / joker | UI | Node | 変更なし（joker の NOIR_URL / VIOLET_URL の向き先だけ変わる） |

**変えないもの**: 文書ストアのレイアウトと JSON の形（`{id[0:2]}/{id[2:4]}/{id}/`、`json/*.json`、`images/*.webp`）、文書ID=XML の SHA-256、ES のマッピング。これを守れば fox・joker・skull・mona は無変更（または向き先変更だけ）で動く。移行の検証も「旧実装と新実装の出力 JSON を突き合わせる」で済む。

## 2. 目標構成

```
                     ┌──────────────── navi (Rust, 1 process) ─────────────────┐
cron / タスクスケジューラ │  HTTP: 管理 UI / 制御 API / クエリ埋め込み API            │
   POST /api/etl/start ─┤                                                         │
                     │  Job manager ── Pipeline ─┬ scan(xml) ┬→ extract → transform → … → upload ─→ ES
                     │                           └ scan(html)┘                      │
                     │  Model host (ruri + CLIP, Arc 共有) ←── ETL ワーカー          │
                     │                                    ←── /api/embeddings/*  ←── joker
                     │  State DB (SQLite)                                          │
                     └─────────────────────────────────────────────────────────────┘
phantom mona (Rust, 別プロセス・読み取り専用) ← fox / joker
skull (Node) / fox / joker (Node) / ES / nginx
```

単一バイナリ `phantom` にサブコマンドを持たせる:

- `phantom navi` — ETL + 管理 UI + クエリ埋め込み API
- `phantom mona` — 文書ストア配信（複製側に置ける唯一のサービス、という [deployment-topology] の方針を維持）
- `phantom etl run --source xml --limit 100` — UI を介さない単発実行（デバッグ・検証用）
- `phantom dev build-json-schema` — 現 `scripts/build-json-schema.sh` の saxonche 部分の置き換え（§4.2 の Saxon バインディングを流用）

Docker では同じイメージを command 違いで2コンテナ。Windows ではバイナリ + DLL 群を1フォルダに置く。

## 3. ETL の新ループ

### 3.1 「1件ずつ」と「並列」の両立

素朴に「1件を全ステージ通してから次へ」にすると、OCR（約2.4 秒/枚）の間 CPU の他のコアが遊ぶ。そこで**文書単位で流れる、ステージごとに資源を分けたパイプライン**にする。各文書は自分の順番どおりに全ステージを通り、終わった時点で ES に入る。複数の文書が別々のステージに同時にいる。

```
scan ─→ [extract] ─→ [transform] ─→ [images] ─→ [ocr] ─→ [embed-image] ─┐
                                 └→ [properties] ─→ [embed-text] ─────────┴→ [assemble] ─→ [upload]
```

ステージ間は**有界チャネル**（tokio mpsc、容量は数件）。下流が詰まると上流が止まるので、メモリに滞留する文書数は一定に収まる。

### 3.2 実行レーン（資源の割り当て）

2026-08-11 の実測（Linux 開発機）に従い、処理の性質ごとにレーンを分ける。

| レーン | ステージ | 並列度の既定 | 根拠 |
| --- | --- | --- | --- |
| io | scan, extract, upload | tokio（非同期） | I/O 待ちが主 |
| xslt | transform | **1 スレッド固定** | SaxonC はスレッドに isolate を結び付ける必要があり、現状もロックで直列。113 ms/文書で律速にはならない |
| pixel | images（デコード・リサイズ・webp）、CLIP 前処理 | rayon、**論理コア数 − 1** | Pillow 実測で SMT まで伸びた。Rust でも同傾向のはず |
| ocr | tesseract 子プロセス | **物理コア数**（上限設定可）、`OMP_THREAD_LIMIT=1` | 全体の律速。1枚1プロセスで並べる |
| infer | embed-text, embed-image | **1 レーン、intra-op = 物理コア数** | torch で SMT まで使うと激遅になった。ORT でも同じ罠があると仮定し、既定は物理コア。クエリ API もこのレーンに割り込む（優先度付き） |

ocr と infer はどちらもコアを食い合うので、「ocr 並列度 + infer スレッド数 ≦ 物理コア数 + α」を設定の目安として管理 UI に表示する。最適値は実機で測る（§10 のスパイク）。

### 3.3 冪等性・再開

- 文書ストアのファイルを**正**とする方針は維持。各ステージは今と同じ「出力ファイルを最後に書く＝処理済みマーカー」で、途中で落ちたらそのステージからやり直し
  - `json/document.json`（transform）、`json/document-properties.json`（properties+embed-text）、`json/images-properties.json`（ocr+embed-image）、`json/images-information.json`（images）、`json/doc.json`・`img.json`（upload）
- 加えて **状態 DB（SQLite、rusqlite の bundled 版。Windows でも追加インストール不要）** を持つ。これは**キャッシュであって正ではない**。消しても文書ストアから再構築できる
  - `sources(path, size, mtime, doc_id, last_seen)` — 再スキャン時に size/mtime が同じならハッシュ計算と展開済み判定を省く。数十万件のソースを毎回全部読む現状のコストがここで消える
  - `documents(doc_id, source_kind, stage, status, error, updated_at)` — UI の進捗・失敗一覧・失敗分だけ再実行、に使う
  - `runs(run_id, started_at, finished_at, params, counters)` — 実行履歴
- 中止は `CancellationToken`。scan が新規投入をやめ、各ステージは手元の文書の現ステージを終えて捨てる（マーカーを書く前なら次回やり直し）。即時性が要るなら tesseract 子プロセスは kill

### 3.4 ES への反映

- upload は文書ごとに bulk リクエストを溜め、**N 件または T 秒**（既定 50 件 / 2 秒）で flush。1件ずつ送るより ES の負荷が軽く、反映遅延は数秒
- refresh は ES の `refresh_interval` に任せる（明示 refresh はしない）
- 「doc.json と内容一致なら登録済み」の panther の判定はそのまま

### 3.5 XML 系と HTML 系

scan だけ2種類（xml / html）で、下流は共通にする。cendrillon は今「crow+queen+noir+violet 相当を自前で一気通貫」しているが、新構成では HTML 系の `extract`・`transform`（HTML→document.json / document-properties の書誌部分）だけが固有で、images・ocr・embed・upload は XML 系と同じステージを通る。cendrillon が API 経由でモデルを借りていた理由（モデルの二重常駐）は、同一プロセスになるので自然に解消する。

1回の実行（run）は `sources: ["xml", "html"]` を受け取り、両方の scan を合流させる。

## 4. 技術要素ごとの判断

### 4.1 libefiling

| Python | Rust |
| --- | --- |
| zipfile | `zip` |
| asn1crypto.cms.SignedData | `cms`（RustCrypto）または `der` で必要部分だけ手書き。署名検証はしていないはずなので、中身の取り出しだけでよい |
| email.message_from_bytes | `mail-parser` |
| struct | `byteorder` / スライス操作 |
| charset 変換 | `encoding_rs`（Shift_JIS/cp932） |
| xml.etree | `quick-xml`（ストリーム）または `roxmltree`（DOM、読み取り専用で速い） |
| hashlib | `sha2` |
| pydantic (manifest) | `serde` |

`libefiling-rs` として独立クレートにする（phantom ワークスペース内でも別リポジトリでもよい）。検証は**テストデータ全件で Python 版と展開結果（ファイル一覧・バイト列・manifest.json）を完全一致**させる。

### 4.2 XSLT（最大のリスク）

現状の XSL は 3.0 の機能に依存している: `xml-to-json()`、`xf:map`/`xf:array` の XML 表現、`xsl:function`、`as=` の型付き変数、`format-date`、`tokenize/replace/matches`、`xsl:map`。計 18,000 行。

| 案 | 内容 | 長所 | 短所 |
| --- | --- | --- | --- |
| **A. SaxonC-HE を FFI**（第一案） | SaxonC の C++ API（`Xslt30Processor` / `XsltExecutable`）を薄い C++ シム（数十〜百行）で包み、`cc` クレートでビルドして Rust から呼ぶ。コンパイル済みスタイルシートはキャッシュ | XSL 無変更。旧 queen と**同じエンジン**なので document.json をバイト一致で検証できる。型生成パイプライン（schema-dsl.xsl）もそのまま | 公式 Rust バインディングは無く、シムは自前保守。DLL（数十 MB）を同梱。純 C API（`SaxonCProcessor.h`）だけだとスタイルシートのキャッシュが効かず、旧 queen の最適化前（324 ms/文書）に戻る |
| B. XSLT 1.0 + libxslt | XSL を 1.0 に書き直し、出力は `xf:map` 形式の **XML** のまま出して、JSON 化（`xml-to-json` 相当、数十行）は Rust 側でやる。`xsl:function` → 名前付きテンプレート、`tokenize` 等 → EXSLT `str:`、`format-date` → 文字列操作 | エンジンが成熟。型付き変数が消えるので [xsl-lazy-eval-trap] の類が原理的に起きない | 18,000 行の書き直しと全件の出力突き合わせ。regex 系（matches/replace）は EXSLT に無く、テンプレートで代替。libxslt の Windows ビルド（vcpkg） |
| C. XSL を Rust コードに移植 | noir が bibliographic-items.xsl を ElementTree に移植したのと同じ方針 | 依存ゼロ・最速 | 書き直し量が最大。schema-dsl.xsl による JSON Schema → TS 型生成が使えなくなる |
| D. 純 Rust の XSLT 実装（xrust 等） | — | — | 3.0 の実装が実用段階にない。不採用 |

**推奨は A**。A で動かしたうえで、Windows 版 SaxonC の入手性やシムの保守が負担になったら B に移る。B に移る場合も「Rust で xf:map XML → JSON」という分担にすれば、XSL 側の書き直しは `xml-to-json` を外すだけで JSON 生成ロジックには触れずに済む部分が多い。

確認事項: Saxonica の製品ページでは SaxonC 13 が Windows 対応とされている一方、Windows 向け配布物が遅れているという記述もある。**最初のスパイクで「Windows で SaxonC-HE の DLL を入手してシムがリンクできるか」を確かめる**。

### 4.3 画像処理

| 処理 | クレート | 備考 |
| --- | --- | --- |
| GIF / JPEG デコード | `image` | 問題なし |
| TIFF（**CCITT G4、1bit**。実データ 107 枚すべてこれ） | `tiff` + `fax` | `fax` クレート（pdf-rs）が G4 のデコードに対応。`tiff` クレート単体で G4 を読めるかは未確認なので、タグ解析は `tiff`、ストリップの伸長は `fax` という組み合わせを想定。**スパイクで実データ全件のデコードを確かめる** |
| リサイズ | `fast_image_resize`（SIMD） | Pillow より速いはず。画素は Pillow と一致しない（寸法は一致させる） |
| WebP（非可逆） | `webp`（libwebp のバインディング、ソース同梱でビルド） | `image` クレートの WebP エンコーダは可逆のみなので不可。Pillow と同じ quality=80・method=2 を指定 |
| 画像種別判定（detect_image_kind） | 自前移植 | queen のロジックをそのまま |

### 4.4 OCR

- **tesseract を子プロセスで呼ぶ**（`tesseract stdin stdout -l jpn+eng`、画像は PNG で stdin に渡す）。pytesseract と同じ方式なので結果も同じになるはず
- Linux: Docker イメージに `tesseract-ocr` + `tesseract-ocr-jpn` を入れる（現状どおり）
- Windows: UB Mannheim 版をユーザーがインストール。`TESSERACT_PATH` と `TESSDATA_PREFIX` を設定ファイルで指定
- libtesseract を直接リンクする案（`leptess` 等）は、Windows でのビルドが重くなる割に速度差が小さい（処理本体は同じ）ので採らない
- 将来の選択肢: PaddleOCR の日本語モデルを ONNX で ort から呼ぶ。tesseract 不要になり、図面中の文字で精度が上がる可能性がある。ただしモデル選定と評価が別仕事になるので本設計の範囲外

### 4.5 エンベディング

- 実行系: **`ort`（ONNX Runtime）+ `tokenizers`（HF、Rust ネイティブ）**
  - `candle`（純 Rust）も候補だが、open_clip の xlm-roberta-base-ViT-B-32 をそのまま組める実装が無く、自前で組むことになる。ort ならモデル構造を気にしなくてよい
- モデルの準備（一度だけ、開発機で Python を使ってよい作業）
  - ruri-v3-130m（ModernBERT）: ONNX に書き出し。プーリング（mean）と L2 正規化はグラフに含めるか Rust 側で実装
  - CLIP: 画像タワーとテキストタワーを**別々の ONNX**に書き出す。ETL は画像タワー、joker のクエリは両方使う。現 violet の `image_only=True` と同じ発想でメモリを抑えられる
  - 書き出し手順は `tools/export-onnx/` に Python スクリプトとして残す（ランタイムには不要）
- 前処理の再実装
  - ruri: `tokenizer.json` を読むだけ。「検索文書: 」「検索クエリ: 」のプレフィックス、`max_seq_length=1024` は現行どおり
  - CLIP: open_clip の preprocess（bicubic リサイズ・センタークロップ・正規化）を Rust で書く。Pillow とリサイズの画素が一致しないので、ベクトルは微差が出る
- **検証と移行**: 旧ベクトルとのコサインを全件で測り、平均 0.999 以上なら混在を許容、そうでなければ全件再計算。クエリ側（joker 経由）も新実装に切り替わるので、**「文書側は旧、クエリ側は新」の期間を作らない**ように、切替は一斉に行う（ES の旧インデックスを残し、新インデックスに全件入れ終わってからエイリアスを切り替えるのが安全）
- スレッド数: `intra_op_num_threads` は物理コア数を既定に。torch で見つかったスレッド数の罠が ORT でも起きるかは要測定
- GPU: ort の CUDA / DirectML 実行プロバイダで将来対応可能（Windows なら DirectML が手軽）。初期スコープ外

### 4.6 Elasticsearch

`elasticsearch` 公式 Rust クライアントは長く alpha のままなので、**`reqwest` で REST を直接叩く**（使うのは bulk・index 作成・mapping 取得・get 程度）。マッピングは `infra/es/*.json` をそのまま読む。

### 4.7 HTML 系（cendrillon 相当）

cp932 の `<PRE>` テキストのラベル解析とファイル名の固定長フィールド（cp932 バイト長 169 / 71）。`encoding_rs` で cp932 化してからバイト長を見る現行ロジックをそのまま移植する。Windows ではファイル名が UTF-16 で来るが、cp932 に変換してから数える点は同じなので挙動は変わらない。HTML パースは `<PRE>` 抽出程度なら `scraper` か手書きで足りる。

## 5. モデルの置き場所（ご質問への回答）

**navi プロセスに常駐させ、ETL とクエリ API で共有する**のを推奨する。

```rust
trait TextEmbedder { fn embed_document(&self, text: &str) -> Vec<f32>; fn embed_query(&self, text: &str) -> Vec<f32>; }
trait ImageEmbedder { fn embed_image(&self, img: &RgbImage) -> Vec<f32>; fn embed_text(&self, text: &str) -> Vec<f32>; }
// 実装: LocalOrt（同一プロセス） / Remote（HTTP、別プロセスに分けたいとき）
```

- 理由
  - モデルを1つだけ持てばよい（今は noir・violet が常駐、cendrillon が借りる構成。その形を1プロセスに畳んだもの）
  - ort の `Session` はスレッド安全で、ETL とクエリが同じ実体を使える
  - Windows で常駐させるプロセスが1つ減る
- 遅延ロード: 最初の呼び出しでロード。ETL もクエリも無い状態が一定時間続いたら解放するオプション（`NAVI_MODEL_IDLE_UNLOAD`）
- クエリの優先: infer レーンに優先度付きキューを置き、joker からのクエリは ETL の待ち行列を追い越す。ETL 中も検索のレイテンシが数百 ms 程度で収まるようにする
- joker 向け API は**現行と同じパス・形**で出す（`POST /embeddings/query`（ruri）と、CLIP テキスト用に別パス）。joker 側は `NOIR_URL` / `VIOLET_URL` を navi に向けるだけで済む。将来 joker の設定を `EMBEDDING_URL` 1本にまとめてもよい
- 分離が必要になったら: `phantom embedder` サブコマンドで同じコードを別プロセスとして起動し、navi は `Remote` 実装に切り替える。ETL を止めて navi を再起動しても検索が止まらない、が欲しくなったらこの形

## 6. navi の API と UI

| Method | Path | 説明 |
| --- | --- | --- |
| POST | `/api/etl/runs` | 実行開始。`{"sources": ["xml","html"], "limit": null, "retryFailed": false}`。実行中なら 409 |
| POST | `/api/etl/runs/current/cancel` | 中止 |
| GET | `/api/etl/runs/current` | 現在の実行の状態（ステージごとの処理中件数・完了件数・失敗件数・スループット） |
| GET | `/api/etl/runs` | 実行履歴 |
| GET | `/api/etl/events` | SSE。UI はポーリングでなくこれを購読 |
| GET | `/api/etl/failures` | 失敗文書の一覧（doc_id、ステージ、エラー） |
| POST | `/api/embeddings/...` | §5 のクエリ埋め込み |
| GET | `/api/services` | mona / fox / joker / skull / ES の health（現行の監視を継続） |
| GET | `/health` | |

- cron / Windows タスクスケジューラからは `curl -X POST .../api/etl/runs` を叩く（`phantom etl trigger` サブコマンドも用意すると Windows で curl を気にしなくてよい）
- UI は現行どおり静的 HTML + JS をバイナリに埋め込む（`rust-embed`）。ビルドツールは増やさない
- Web フレームワークは `axum`

## 7. skull と mona

**skull: Node（Astro）化を推奨。**
- skull は CRUD + SQLite + ES 同期で、Rust にして速くなる要素が無い
- 将来の特許管理システム（担当者・タグ・作業メモ…）は UI が主役になる。fox・joker と同じ Astro に揃えると、UI 部品・ES クライアント（`@elastic/elasticsearch`）・型を共有できる
- SQLite は Node 22.5+ の組み込み `node:sqlite` を使えばネイティブモジュールのビルドが要らず、Windows でも楽
- 反対意見: Rust にすれば navi と同じバイナリに入り、Windows で常駐プロセスが1つ減る。プロセス数を最優先するならこちら

**mona: Rust（`phantom mona`）。** 90 行の静的配信なので `tower-http::ServeDir` + doc_id 検証で済む。navi に同居させずに別プロセスとしたのは、複製側に置けるのが mona だけという方針を保つため（navi は正本側でしか動かない）。同居モード（`phantom navi --with-mona`）も用意しておけば、Windows の単機運用では1プロセスで済む。

これで**ランタイムは Rust バイナリ + Node の2種類**になり、Python が消える。

## 8. Windows ネイティブ運用

| 項目 | 方針 |
| --- | --- |
| 配布 | `phantom.exe` + `saxon-hec.dll` + `onnxruntime.dll` + `models/` を1フォルダに。GitHub Actions の windows-latest でビルドして zip をリリースに添付 |
| 設定 | 環境変数に加えて **TOML 設定ファイル**（`phantom.toml`）。Windows で環境変数を管理するのは面倒なため。優先順位は 環境変数 > 設定ファイル > 既定値 |
| 入力元 | ネットワークドライブは **UNC パス（`\\server\share\...`）で指定**。ドライブレターの割り当てはログオンセッションに紐づき、サービスとして動くと見えないため |
| パス | 文書ストアのパスは短いので MAX_PATH の問題は出にくいが、`dunce` で正規化して `\\?\` 付きパスが外部（tesseract 等）に漏れないようにする |
| 常駐 | まずはタスクスケジューラの「ログオン時に起動」で十分。サービス化するなら `windows-service` クレートでネイティブ対応、または NSSM |
| 外部依存（ユーザーが入れる） | Elasticsearch、nginx、tesseract（+jpn）、Node（fox・joker・skull 用） |
| モデル | 初回起動時に HF からダウンロード、または zip に同梱。ONNX 化済みのものを自分の HF リポジトリか GitHub Release に置くのが楽 |
| ログ | ファイル出力（`tracing-appender` で日次ローテーション）。Docker では stdout |

Linux + Docker は今と同じ compose 運用。サービス数が crow/queen/noir/violet/cendrillon/panther/navi/mona/skull の 9 個から navi/mona/skull の 3 個に減る。

## 9. クレート構成

```
rust/                        (Cargo workspace)
  crates/
    libefiling/              アーカイブ展開（Python 版の移植）
    docstore/                文書ID→ディレクトリ規則、マーカー判定
    whitelist/               書類コード・書類名の対象表
    jpoxml/                  XML マージ、Saxon シム呼び出し、xf:map→JSON
    saxon-sys/               SaxonC の C++ シム + FFI
    imaging/                 デコード・リサイズ・webp・画像種別
    ocr/                     tesseract 子プロセス
    embed/                   ort + tokenizers、Embedder trait
    properties/              noir の書誌・本文抽出（ElementTree 版の移植）
    htmldoc/                 cendrillon の HTML 解析
    esclient/                bulk・インデックス作成
    pipeline/                ステージ・レーン・チャネル・状態 DB
  bins/
    phantom/                 サブコマンド（navi / mona / etl / dev）
tools/export-onnx/           モデルの ONNX 書き出し（Python、開発時のみ）
```

Python の `libs/python/*` と `services/{crow,queen,noir,violet,cendrillon,panther,navi,mona}` は、移行完了後に削除。

## 10. 移行手順

各段階で「旧実装の出力と突き合わせる」を合格条件にする。突き合わせ用に `phantom dev diff-store <old> <new>` を最初に作る（JSON はキー順を正規化して比較、webp は寸法のみ、ベクトルはコサイン）。

| # | 内容 | 合格条件 |
| --- | --- | --- |
| 0 | **スパイク**（捨てる前提で小さく） ① Windows で SaxonC シムがリンク・変換できるか ② G4 TIFF を `tiff`+`fax` で全件デコードできるか ③ ruri / CLIP を ONNX にしてコサインと速度を測る ④ ORT のスレッド数と速度の関係（SMT の罠の有無） | ①②が通らなければ §4.2 B 案・別デコーダに設計変更 |
| 1 | libefiling-rs | テストデータ全件で展開結果がバイト一致 |
| 2 | jpoxml（Saxon）+ imaging + properties | document.json・document-properties.json（埋め込み以外）がバイト一致、images-information.json は寸法一致 |
| 3 | embed + ocr | ocrText 一致、ベクトルのコサイン ≥ 0.999（未達なら全件再計算の計画に切替） |
| 4 | esclient + pipeline（新ループ）+ navi UI/API | 新インデックスに全件投入、旧インデックスと件数・doc.json 一致 |
| 5 | htmldoc（cendrillon 相当） | cendrillon の出力と一致 |
| 6 | joker の向き先変更、ES エイリアス切替、旧サービス停止 | joker の検索結果が同等 |
| 7 | Windows ビルド・配布・運用手順書 | Windows 実機で取り込み〜検索まで通る |
| 8 | skull の Node 化（独立して進められる） | 既存 SQLite をそのまま読める |

## 11. 決めてほしいこと・教えてほしいこと

設計の分岐になる制約で、コードからは分からないもの:

1. **Windows 機のスペック**（コア数・メモリ・GPU の有無）。レーンの既定値と、GPU 実行プロバイダを初期スコープに入れるかが変わる
2. **埋め込みベクトルの微差の許容**。Rust 化で前処理と実行系が変わるのでベクトルは厳密一致しない。全件再計算（初回 ETL と同等の時間）を一度やってよいか
3. **XSLT の B 案に落ちる場合の覚悟**。SaxonC の Windows 版が手に入らない、またはシムの保守を嫌う場合に、18,000 行を 1.0 化する作業を受け入れるか
4. **skull は Node でよいか**（§7。プロセス数を優先するなら Rust）
5. **ETL 実行中の検索レイテンシの許容値**。ETL と検索が同じ CPU を使うので、クエリ優先度の設計に効く
