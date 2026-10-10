# Bonbori

Apple Silicon Mac 用のテレビ視聴アプリです。[BonDriverProxyEx](https://github.com/HaijinW/BonDriverProxyEx) サーバーに直接つないで、地デジ・BS・CS を視聴します。選局してから映像が出るまでの速さを重視しています。
Windows の [TVTest](https://github.com/DBCTRADO/TVTest) の動作を大いに参考にしていますが、TVTest の移植版や公式の関連プロジェクトではありません。

## ビルド

必要なもの: Command Line Tools（Swift 6 系）、Homebrew の ffmpeg（`brew install ffmpeg`）。

```sh
./build-app.sh        # → Bonbori.app を生成
open Bonbori.app
```

初回起動時に「ローカルネットワークへのアクセス」の許可を求められるので、許可してください。

## 初期設定

1. 初回起動時に設定画面が開くので、BonDriverProxyEx サーバーのアドレス、ポート（初期値 `1192`）、グループ（初期値 `BonDriver-T,BonDriver-S`）を入力します。あとから `⌘,` で変更できます。
2. メニュー「チャンネル」→「チャンネルスキャン…」を実行します。地デジは電波の無い ch で 1ch 約 5 秒かかるので、全体で 5〜7 分ほどです。
   結果は `~/Library/Application Support/Bonbori/channels.json` に保存されます。

## 操作

| キー | 動作 |
|---|---|
| ↑ / ↓ | 前 / 次のチャンネル（今見ている地デジ・BS・CS の中で切り替え） |
| 1〜9, 0, -, ^ | リモコンキー 1〜12 |
| T / B / C | 地デジ / BS / CS に切り替え |
| ← / → / ホイール | 音量 |
| M | ミュート |
| D | 二重音声（主+副 / 主 / 副） |
| A | 音声ストリームの切り替え |
| I | 情報表示（信号・ビットレート・ドロップ数・フォーマット） |
| L | チャンネル一覧 |
| E / ⌘E | 番組表 |
| Space | 番組情報を表示 |
| R | 録画の開始 / 停止（TS をそのまま `~/Movies/Bonbori/` に保存） |
| P | キャプチャ（PNG を `~/Pictures/Bonbori/` に保存） |
| F / Return / ダブルクリック | フルスクリーン |
| 右クリック / Control+クリック | メニュー（選局・録画・キャプチャ・音声・表示・設定） |

## 番組表

`E`（またはメニュー「チャンネル」→「番組表」）で開きます。視聴中に流れてくる EIT（p/f と schedule）をすべて蓄積しているので、見たことのあるチャンネルの番組は最初から表示されます。
BS/CS はどのトランスポンダにもネットワーク内の全サービスの番組表（基本情報）が流れているため、1 チャンネル見ているだけで BS 全体・CS 全体の約 8 日分が数分で揃います。

- ツールバー: 地デジ / BS / CS の切り替え、日付（放送日は 4:00 始まり）、現在時刻へ移動、番組表の取得、検索、インスペクタ
- 番組をクリックすると右のインスペクタに詳細（拡張番組情報・ジャンル・映像/音声）を表示。ダブルクリックまたは Return で放送中なら選局
- 上端のチャンネル名をクリックで選局。矢印キーで番組を移動、ピンチまたは ⌘+ / ⌘- で時間軸の拡大縮小、⌥⌘F で検索
- **番組表の取得**: ツールバーのボタン（▼ で放送の種類を選択）またはメニュー「チャンネル」→「番組表の取得」。TVTest と同じ考え方で、視聴中のチューナーでチャンネルを巡回し、各 TS の schedule が揃うまで（地デジは最大 2 分、衛星は最大 6 分）待ちます。BS/CS はネットワークごとに 1 TS だけ回ります。終わると元のチャンネルに戻ります。録画中は取得できず、取得中に手動で選局すると中止します。
- データは `~/Library/Application Support/Bonbori/epg.json` に保存（前日より前に終わった番組は削除）

## 構成

```
Sources/TVCore (C)          BonDriverProxyEx プロトコル、TS デマルチプレクサ、ARIB 文字列、FFmpeg デコーダ
  session.c   TCP クライアント。受信スレッドで TS を受け取り、選局の応答を境に世代(gen)を切り替える
  demux.c     PAT/PMT/SDT/NIT/EIT/TOT、PES 組み立て、PCR、33bit ラップ処理、
              EIT（全サービスの p/f・schedule）を section 単位で重複除去して JSON で渡す、
              PMT が確定する前のパケットをリングバッファから再生して I フレームを取りこぼさない
  arib.c      ARIB STD-B24 8 単位符号 → UTF-8（JIS X 0208 は iconv、追加記号の一部）
  decoder.c   libavcodec（MPEG-2/H.264/HEVC/AAC）、bwdif によるフィールドレート（59.94fps）のインタレース解除、
              NV12 の IOSurface CVPixelBuffer / LPCM の CMSampleBuffer を作る
Sources/Bonbori (Swift/AppKit)
  Player.swift  AVSampleBufferDisplayLayer + AVSampleBufferAudioRenderer + RenderSynchronizer。
                選局時に同期器の時計を放送の PCR に合わせ（PCR − 遅延）、あとは音声デバイスの時計で進める
  EPG.swift     番組データベース（EIT の取り込み、共通番組の解決、schedule の受信完了判定、保存）
  EPGCapture.swift          番組表の取得（チャンネル巡回）
  ProgramGuideWindow.swift  番組表ウインドウ（NSToolbar・NSSplitViewController のインスペクタ）
  ProgramGridView.swift     番組表のグリッドとチャンネル名・時刻の見出し
  ProgramDetailView.swift   インスペクタの番組詳細（SwiftUI）
Sources/tvprobe             コマンドラインの動作確認ツール
```

選局の流れ: `SetChannel2` を送ってから応答が来るまでに届いた TS は捨てます。サーバーは応答より後に送る TS が新しいチャンネルのものだと保証しているので、応答を受け取った時点でデマルチプレクサとデコーダをリセットします。そのあと最初の I フレームをすぐ表示（DisplayImmediately）し、続きは PCR に合わせた時計に従って再生します。

実測の選局時間（選局要求から映像が出るまで）:

- BS: 0.4〜0.9 秒（チューナーの選局応答は約 190ms）
- 地デジ: 0.9〜1.4 秒（PX4 の選局応答に約 650ms かかる）
- ほかのクライアントが受信中のチャンネル（チューナー共有）: 約 0.2〜0.4 秒

## サーバー側の注意

- **スクランブル**: Bonbori 自体はスクランブルの解除を行いません。視聴には、サーバーから解除済みの TS が届く構成が必要です。設定の「サーバー側でスクランブル解除を要求する」をオンにすると、選局時に BonDriverProxyEx プロトコルの `eDesireToUseB25` を付けて要求します。解除されていない放送を受信すると、画面にその旨を表示します。
- **遅延をさらに短くしたいとき**: サーバー ini の `TSPACKET_BUFSIZE`（初期値 192512 = 地デジで約 90ms 分）を小さくすると、送信単位が小さくなって遅延が減ります。
- **チューナーの共有**: BonDriverProxyEx は空いているチューナーを優先して使います。ただし全部使用中で、ほかのクライアントがチャンネルロックを使っていない場合は、そのクライアントのチューナーのチャンネルを変えてしまうことがあります（サーバーの仕様）。録画ソフトは `CHANNEL_LOCK` を設定しておくと安全です。

## デバッグ

```sh
BONBORI_DEBUG=1 .build/release/Bonbori          # 選局時間・A/V の余裕・時計のずれのログ（時刻付き）を stderr に出す
BONBORI_DEBUG=1 BONBORI_ZAP_TEST=5 .build/release/Bonbori   # 5 秒ごとに自動でザッピングする
BONBORI_GUIDE=1 .build/release/Bonbori          # 起動時に番組表を開く（BONBORI_DEBUG=1 で番組表取得の各局の完了/タイムアウトも出す）
.build/release/tvprobe <サーバーのアドレス> BonDriver-T 0 4 5   # コアだけで受信テスト（space 0 / ch 4 を 5 秒）
REC=/tmp/out.ts .build/release/tvprobe <サーバーのアドレス> BonDriver-S 0 16 90 245   # 受信した TS をそのまま保存（解析用）
```

旧名の `ITV_DEBUG` などの環境変数も、当面はそのまま使えます。

## 未実装

- 字幕（ARIB 字幕のデコードと描画）
- 番組表の予約・キーワード検索の保存（今は表示と選局、表示中の放送内の検索のみ）
- ハードウェアデコード（今は MPEG-2 ソフトウェアデコード＋bwdif で、地デジ視聴時は 1 コアの 20〜35%、M1 全体では数 %）

## 参考にしたもの・謝辞

- [TVTest](https://github.com/DBCTRADO/TVTest)（DBCTRADO, GPL-2.0-or-later）: 番組表の取得（チャンネル巡回と完了判定）、ジャンル名、チャンネルの並び順、番組表の操作などの動作を参考にしています。
- [LibISDB](https://github.com/DBCTRADO/LibISDB)（DBCTRADO, GPL-2.0-or-later）: ARIB 追加記号の文字列表記、音声タイムスタンプの許容ずれなどを参考にしています。
- [BonDriverProxyEx](https://github.com/HaijinW/BonDriverProxyEx)（MIT License）: 通信プロトコル（`inc/BdpPacket.h`）に従って実装しています。
- [FFmpeg](https://ffmpeg.org/): 映像・音声のデコードとインタレース解除に使っています。
- ARIB STD-B10 / STD-B24 などの規格。

## 免責事項

- Bonbori は個人のプロジェクトです。Apple、TVTest・LibISDB の作者、ARIB、各放送事業者とは関係ありません。
- 放送の受信・視聴・録画は、受信契約や著作権法などの法令の範囲で行ってください。録画した TS は私的利用の範囲で扱ってください。
- 無保証です。詳しくはライセンスを参照してください。

## ライセンス

[GNU General Public License v2.0 or later](LICENSE)（GPL-2.0-or-later）。

Homebrew の ffmpeg は GPL（v3）の構成でビルドされているため、それにリンクした Bonbori のバイナリを配布する場合は GPL v3 の条件に従う必要があります。
