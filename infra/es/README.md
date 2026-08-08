# Elasticsearch マッピング

`DST_DIR` 配下に各サービスが生成する JSON を Elasticsearch に登録するための
インデックスマッピング。phantom-old の doc-mapping.json / img-mapping.json を
新パイプラインの出力に合わせて再構成したもの。

| ファイル | インデックス | データソース |
| --- | --- | --- |
| `doc-mapping.json` | 文書（1文書=1ドキュメント） | noir の `json/document-properties.json` |
| `img-mapping.json` | 画像（1画像=1ドキュメント） | violet の `json/images-properties.json` + queen の `json/images-information.json` + `document-properties.json`（書誌の非正規化） |

## 前提プラグイン

- `analysis-kuromoji`（日本語形態素解析）
- `analysis-icu`（NFKC 正規化）

## インデックス作成

```bash
curl -X PUT localhost:9200/documents \
  -H 'Content-Type: application/json' \
  --data-binary @doc-mapping.json

curl -X PUT localhost:9200/images \
  -H 'Content-Type: application/json' \
  --data-binary @img-mapping.json
```

## 文書インデックス（doc-mapping.json）

`document-properties.json` のキーをそのまま登録する前提。追加で登録側が
付与するのは `docId`（文書ディレクトリ名 = XML の SHA-256。`_id` にも使う）のみ。

- `task` / `kind` / `extension` — manifest.json 由来（noir 機能A）
- 書誌事項（`law`・`documentName`・各種番号・`datetime`・出願人など）— noir 機能B
- 文書テキスト（`inventionTitle` … `dependentClaims` など）— noir 機能B。
  kuromoji + 2-gram のマルチフィールド
- `embeddings` — noir 機能C。cl-nagoya/ruri-v3-130m の 512 次元・cosine。
  テキストが空の文書にはキー自体が無い（dense_vector は欠損可）。
  `embeddingModel` / `embeddingDimensions` で登録時にモデル・次元の整合を検証する
- `ocrText` — violet の `images-properties.json` 由来。同一文書の全画像の
  `ocrText` を登録側で連結して1フィールドにする。OCR 対象画像
  （queen の `detect_image_kind` が `other-images`）は英語版明細書が約8割・
  日本語論文が約2割のため、メインアナライザは `english`（ステミング付き）、
  日本語検索用に `ocrText.ja`（kuromoji）、部分一致用に `ocrText.ngram` を併設。
  検索時は `ocrText` / `ocrText.ja` / `ocrText.ngram` を multi_match でまとめて
  当てるとよい

- `intRefNumber` / `extRefNumber` / `tags` / `assignees` — skull が管理する
  メタ情報（[skull](https://github.com/hyperion13th144m/phantom/blob/main/services/skull/README.md)）。panther は登録せず、
  skull の同期タスクが後から付与・更新・削除する（画像インデックスにも同じ
  フィールドを持たせ、文書単位で同期する）。既存インデックスには skull が
  `put_mapping` で自動追加する

phantom-old からの変更点:

- `documentEmbedding`（256次元）→ `embeddings`（512次元）。キー名・次元とも
  noir の出力に合わせた。モデルを変える場合は `dims` を連動して変更する
- `ocrText` のデータソースを画像側 JSON からの集約に変更し、アナライザを
  kuromoji から `english` に変更（英語文書の検索用）
- noir が出力しない `embeddingVersion` / `embeddingGeneratedAt` /
  `embeddingTextHash` / `embeddingSourceFields` を削除

## 画像インデックス（img-mapping.json）

1画像 = `images-properties.json` の1要素。`_id` は `{docId}/{filename}` を推奨。

- `docId` / `filename` — 登録側が付与（filename は両 JSON の突き合わせキー）
- `figureNumber` / `description` / `isRepresentative` / `embeddings`
  — violet の `images-properties.json` 由来。`embeddings` は open_clip
  xlm-roberta-base-ViT-B-32 / laion5b_s13b_b90k の 512 次元・cosine・L2 正規化済み。
  `ocrText` は文書検索用のため画像側には持たず、文書インデックスに集約する
- `kind` / `mediaType` / `derived[]` — queen の `images-information.json` 由来。
  `derived` は 3 サイズ WebP（large / middle / thumbnail）のファイル名と実寸で、
  検索結果のサムネイル表示に使う
- `bibliographic` — 同じ文書の `document-properties.json` から非正規化した書誌。
  画像検索の絞り込み・結果表示をジョインなしで行うため（phantom-old と同じ方針）

phantom-old からの変更点:

- `imageEmbedding` → `embeddings`、`representative` → `isRepresentative`、
  `sourceFilename` + 3つの `*Filename` → `filename` + `derived[]`（violet /
  queen の出力キーに合わせた）
- `ocrText` を文書インデックスへ移動（画像単位では検索しないため）
- パイプラインが生成しなくなった `captionText` / `directMentionText` /
  `sectionText` / `weakContextText` / `linkingConfidence` / `staticTags` /
  `semanticTags` / `contextEmbedding` / `embedding*` メタデータ /
  `ingest_hash` / `ingested_at` を削除
- `bibliographic.law` を追加（noir が出力するため）
