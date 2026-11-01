# Bonbori

Apple Silicon Mac 用のテレビ視聴アプリです。[BonDriverProxyEx](https://github.com/HaijinW/BonDriverProxyEx) サーバーに直接つないで、地デジ・BS・CS を視聴します。選局してから映像が出るまでの速さを重視しています。
Windows の [TVTest](https://github.com/DBCTRADO/TVTest) の動作を大いに参考にしていますが、TVTest の移植版や公式の関連プロジェクトではありません。

## ビルド

必要なもの: Command Line Tools（Swift 6 系）、Homebrew の ffmpeg（`brew install ffmpeg`）、データ放送を使うなら npm（`brew install node`）。

```sh
./build-app.sh        # → Bonbori.app を生成
open Bonbori.app
```

初回起動時に「ローカルネットワークへのアクセス」の許可を求められるので、許可してください。

データ放送の表示には [web-bml](https://github.com/otya128/web-bml) を使います。`build-app.sh` が npm で取得してアプリに取り込みます。npm が無いときはデータ放送なしでビルドします。

放送字幕の内蔵音には [TVCaptionMod2](https://github.com/xtne6f/TVCaptionMod2) の音声を使います。規約があるのでこのリポジトリには含めず、`build-app.sh` が隣の `../TVCaptionMod2`（環境変数 `TVCAPTIONMOD2` で変更可）からアプリに取り込みます。見つからないときはシステムサウンドで鳴らします。

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
| S | 翻訳字幕（英語の音声を日本語に訳して表示）のオン / オフ |
| K | 放送字幕のオン / オフ |
| J | ニコニコ実況のオン / オフ |
| G | データ放送をオンにする。オンの間はリモコンの d ボタン |
| F / Return / ダブルクリック | フルスクリーン |
| 右クリック / Control+クリック | メニュー（選局・録画・キャプチャ・音声・表示・設定） |

## 翻訳字幕

`S`（またはメニュー「字幕」）で、放送中の英語の音声をこの Mac 上で文字に起こし、日本語に訳して画面下に表示します（macOS 26 以降）。MLB 中継の副音声（現地実況）などを想定しています。音声認識は Speech フレームワーク、翻訳は Translation フレームワークで、どちらもオフラインで動きます。

- **字幕の出し方**（メニュー「字幕」）
  - **字幕をできしだい表示**: 映像はそのまま。字幕は話し始めから 3〜6 秒ほど遅れて出ます。
  - **映像を遅らせて字幕に合わせる**: 映像と音声を 6〜12 秒（初期値 8 秒）遅らせて、字幕を話しているときに出します。選局してから映像が出るまでも、その秒数かかります。
- **認識する音声**: 自動（番組情報で二重音声なら副音声、それ以外は左右を混ぜたもの）/ 主音声 / 副音声 / 左右を混ぜる
- 英語の原文を訳文の下に表示するかどうかも選べます。
- 初回は音声認識モデルを自動でダウンロードします。英語→日本語の翻訳モデルが無いときは英語だけを表示します（システム設定 › 一般 › 言語と地域 › 翻訳言語 から追加できます）。
- 実測（M1、MLB 中継の英語実況）: 文字起こしと翻訳を合わせて CPU 1 コアの 1 割未満。訳文は話し終わってから中央値 4 秒、9 割が 6 秒以内に出ます。

## 放送字幕

`K`（またはメニュー「プラグイン」）で、放送に含まれる字幕と文字スーパーを映像の上に表示します（初期状態はオフ）。[TVCaptionMod2](https://github.com/xtne6f/TVCaptionMod2) の機能を参考に、プラグインとして作り直したものです。

- 表示: 放送が指定する位置、色、背景、文字サイズ（半角・倍角など）、縁取り、下線、囲み、点滅に対応します。文字はこの Mac のフォントで画面の解像度に合わせて描きます
- 放送独自の文字（DRCS）と PNG の字幕も表示します。ドットの粗い DRCS は、対応表にあるものなら普通の文字に置き換えます
- 字幕は放送の時刻（PTS）に合わせて出します。「映像を遅らせて字幕に合わせる」を使っているときも映像に合います
- メニュー「プラグイン」で、書体（丸ゴシック / 角ゴシック / 明朝）、文字の背景（放送のとおり / 薄い黒 / なし）、表示のタイミング、文字スーパーの表示、振り仮名を隠す、中央に小さく表示、内蔵音（緊急地震速報のチャイムなど）を切り替えられます。内蔵音はアプリの音量に合わせて鳴り、ミュート中は鳴りません。第 2 言語のある番組では言語も選べます
- システム設定 › アクセシビリティ › 字幕 のスタイルで放送より優先すると指定した項目（文字と背景の色、書体、文字の縁）は、そちらに従います。ただし文字の背景は、メニューで「放送のとおり」以外を選ぶとメニューが優先で、背景を透明にするスタイル（macOS の初期設定）では放送の背景を使います。「視差効果を減らす」がオンのときは点滅させません
- `P` のキャプチャには字幕も写ります
- ワンセグ字幕、UCS 符号の字幕、ブラジル方式の字幕には対応していません。縦書きの字幕は横書きとして表示します

## データ放送

`G`（またはメニュー「プラグイン」）でオンにすると（初期状態はオフ）、放送のデータを受け取り始めます。もう一度 `G` を押すと、テレビの d ボタンと同じようにデータ放送の画面が出ます。映像は画面の中の指定された位置に縮小され、放送字幕と実況コメントも一緒に動きます。[TVTDataBroadcastingWV2](https://github.com/otya128/TVTDataBroadcastingWV2) の機能を参考に、プラグインとして作り直したものです。

- 受信が始まってから表示できるまで数秒から十数秒かかります。放送局によっては初回は 1 分近くかかります
- 操作: データ放送の画面が出ている間は、次のキーがデータ放送に渡ります。文書が使っていないキーは、ふだんどおりの動作になります

| キー | リモコンのボタン |
|---|---|
| ↑ ↓ ← → | 上下左右 |
| Return | 決定 |
| delete | 戻る |
| F1 / F2 / F3 / F4 | 青 / 赤 / 緑 / 黄 |
| 1〜9, 0, -, ^ | 数字（文書が数字キーを使うときだけ。使わないときは選局） |

- メニュー「プラグイン」の「リモコンを表示」で、フローティングのリモコンを出せます。フルスクリーンの映像の上にも出ます。Bonbori が裏に回っている間は隠れます
- 「受信機の設定…」で郵便番号と地域を設定すると、天気予報などが地域のものになります。放送局が受信機に保存した内容もここで削除できます（設定はデータ放送の受信中に開けます）
- 文字の入力が必要なときはシートが開きます。日本語入力もふだんどおりに使えます
- データ放送の効果音はアプリの音量に合わせて鳴ります。文書が音声を切り替えたときは、チャンネルを変えるかプラグインをオフにすると元に戻ります
- `P` のキャプチャには、データ放送の画面が見えているとおりに写ります

外部との通信は、初期状態ではしません。WebKit の中のページは Web に一切アクセスできず（コンテンツルールで全 URL を遮断）、外に出られるのはアプリが中継する BML の通信機能だけです。これを「通信機能を使う」で許可すると、通信コンテンツが使えるようになります。

- サーバーの証明書はこの Mac の信頼設定で検証します。テレビ用の独自のルート証明書を使うサーバーには接続できません
- 文書がブラウザでページを開こうとしたときは、開いてよいか確認します
- ワンセグのデータ放送、Hybridcast には対応していません。マウスでの操作はできません

## ニコニコ実況

`J`（またはメニュー「プラグイン」）で、見ているチャンネルの実況コメントを映像の上に流します（初期状態はオフ）。[NicoJK](https://github.com/xtne6f/NicoJK) の機能を参考に、プラグインとして作り直したものです。

- コメントは [NX-Jikkyo](https://nx-jikkyo.tsukumijima.net/) から受信します。公式のニコニコ実況のコメントも転送されているので、この 1 か所の接続で両方が流れます。地デジ・BS・CS の 33 チャンネルに対応しています。チャンネルは放送のサービス ID から自動で判定します
- 表示: 流れるコメント、上・下の固定コメント、色、大きさの指定に対応します。文字の大きさと不透明度はメニュー「プラグイン」で変えられます
- 「映像を遅らせて字幕に合わせる」を使っているときは、コメントも同じ秒数だけ遅らせます
- `P` のキャプチャにはコメントも写ります
- コメントの投稿、過去ログ、録画への同期再生には対応していません

非公式の API を使っているため、サーバーの仕様変更で動かなくなることがあります。有志が運営するサーバーなので、接続は次のように控えめにしています:

- オフの間、チャンネルに対応する実況がない間、チャンネルスキャンと番組表の取得の間は接続しません
- 同じチャンネルに 3 秒とどまってから接続します。ザッピング中は接続しません
- ウインドウが隠れて 30 秒たつと切断し、見えるようになったら接続し直します
- 接続の試行は 5 秒に 1 回までです。失敗が続くと間隔を倍にしていき、最長 5 分あけます
- 投稿の権限と過去のコメントは要求しません。チャンネル一覧などの定期的な取得もしません

## 番組表

`E`（またはメニュー「チャンネル」→「番組表」）で開きます。視聴中に流れてくる EIT（p/f と schedule）をすべて蓄積しているので、見たことのあるチャンネルの番組は最初から表示されます。
BS/CS はどのトランスポンダにもネットワーク内の全サービスの番組表（基本情報）が流れているため、1 チャンネル見ているだけで BS 全体・CS 全体の約 8 日分が数分で揃います。

- ツールバー: 地デジ / BS / CS の切り替え、日付（放送日は 4:00 始まり）、現在時刻へ移動、番組表の取得、検索、インスペクタ
- 番組をクリックすると右のインスペクタに詳細（拡張番組情報・ジャンル・映像/音声）を表示。ダブルクリックまたは Return で放送中なら選局
- 上端のチャンネル名をクリックで選局。矢印キーで番組を移動、ピンチまたは ⌘+ / ⌘- で時間軸の拡大縮小、⌥⌘F で検索
- **検索**: 番組名と番組の説明から探します。一致する番組を番組表で強調し、左に一覧（これから放送される番組を地デジ・BS・CS すべてから、放送日ごとに時刻順）を表示します。一覧で番組をクリックすると番組表のその番組へ移動（放送の種類も切り替え）、ダブルクリックで放送中なら選局、それ以外は詳細を表示。検索欄で Return を押すと次に一致する番組へ移動します
- **番組表の取得**: ツールバーのボタン（▼ で放送の種類を選択）またはメニュー「チャンネル」→「番組表の取得」。TVTest と同じ考え方で、視聴中のチューナーでチャンネルを巡回し、各 TS の schedule が揃うまで（地デジは最大 2 分、衛星は最大 6 分）待ちます。BS/CS はネットワークごとに 1 TS だけ回ります。終わると元のチャンネルに戻ります。録画中は取得できず、取得中に手動で選局すると中止します。
- データは `~/Library/Application Support/Bonbori/epg.json` に保存（前日より前に終わった番組は削除）

## 構成

```
Sources/TVCore (C)          BonDriverProxyEx プロトコル、TS デマルチプレクサ、ARIB 文字列、FFmpeg デコーダ
  session.c   TCP クライアント。受信スレッドで TS を受け取り、選局の応答を境に世代(gen)を切り替える。
              翻訳字幕用に、音声を遅延なしでもう一度デコードする経路と、映像・音声・時計をデコード前に遅らせる遅延バッファを持つ
  demux.c     PAT/PMT/SDT/NIT/EIT/TOT、PES 組み立て（映像・音声・字幕・文字スーパー）、PCR、33bit ラップ処理、
              EIT（全サービスの p/f・schedule）を section 単位で重複除去して JSON で渡す、
              PMT が確定する前のパケットをリングバッファから再生して I フレームを取りこぼさない
  arib.c      ARIB STD-B24 8 単位符号 → UTF-8（JIS X 0208 は iconv、追加記号の一部）
  decoder.c   libavcodec（MPEG-2/H.264/HEVC/AAC）、bwdif によるフィールドレート（59.94fps）のインタレース解除、
              NV12 の IOSurface CVPixelBuffer / LPCM の CMSampleBuffer を作る
Sources/Bonbori (Swift/AppKit)
  Player.swift  AVSampleBufferDisplayLayer + AVSampleBufferAudioRenderer + RenderSynchronizer。
                選局時に同期器の時計を放送の PCR に合わせ（PCR − 遅延）、あとは音声デバイスの時計で進める。
                放送と音声デバイスの時計の差（数十 ppm）で遅延が減っていかないよう、音声をわずかに伸縮して
                （decoder.c、swr_set_compensation）すべての時刻を同じだけずらし、遅延を保つ
  EPG.swift     番組データベース（EIT の取り込み、共通番組の解決、schedule の受信完了判定、保存）
  EPGCapture.swift          番組表の取得（チャンネル巡回）
  ProgramGuideWindow.swift  番組表ウインドウ（NSToolbar・NSSplitViewController のインスペクタ）
  ProgramGridView.swift     番組表のグリッドとチャンネル名・時刻の見出し
  ProgramDetailView.swift   インスペクタの番組詳細（SwiftUI）
  ProgramSearchView.swift   番組表の検索結果の一覧（SwiftUI）
  Subtitles.swift           翻訳字幕（音声認識・翻訳、PTS に合わせた表示）
  PluginManager.swift       プラグインの管理。本体とプラグインの接点はここだけ
  InstalledPlugins.swift    組み込むプラグインの一覧
Sources/BonboriPluginKit    プラグインから見える API（BonboriPlugin / PluginHost）
Sources/Plugins/Jikkyo      ニコニコ実況
  JikkyoPlugin.swift        いつ接続するかの判断、メニュー
  CommentClient.swift       NX-Jikkyo との通信（URLSession の WebSocket）
  CommentOverlay.swift      弾幕の表示（Core Text で描いた画像を Core Animation で動かす）
  Comment.swift             コメントの表示コマンドの解釈
  ChannelTable.swift        放送サービスから実況番号への対応表（生成）
Sources/Plugins/Captions    放送字幕
  CaptionPlugin.swift       表示するタイミングの管理、メニュー
  CaptionStream.swift       字幕管理データ、言語の選択、DRCS と PNG の解釈
  ARIBCaptionDecoder.swift  字幕文（8 単位符号）から、字幕プレーンに置いた行を作る
  CaptionRenderer.swift     行の描画（Core Text）、システムの字幕スタイルの反映
  CaptionOverlay.swift      字幕プレーン（Core Animation）
  ARIBTables.swift          ARIB の色、追加記号、DRCS の置き換え表（生成）
Sources/Plugins/DataBroadcasting  データ放送
  DataBroadcastingPlugin.swift  ストリームの受け渡し、キー、音声、メニュー
  BMLBrowser.swift              透明な WKWebView。独自スキームでページを配り、ほかの通信を遮断する
  BMLNetwork.swift              通信コンテンツの中継（URLSession）
  RemoteControl.swift           リモコン（NSPanel + SwiftUI）
  ReceiverSettings.swift        受信機の設定（郵便番号・地域）
  TextInput.swift               文字入力のシート
  RemoteKey.swift               ARIB のキーコードとキーボードの対応
Web/DataBroadcasting        WKWebView の中で動くページ。web-bml とプラグインをつなぐ
Sources/tvprobe             コマンドラインの動作確認ツール
```

選局の流れ: `SetChannel2` を送ってから応答が来るまでに届いた TS は捨てます。サーバーは応答より後に送る TS が新しいチャンネルのものだと保証しているので、応答を受け取った時点でデマルチプレクサとデコーダをリセットします。そのあと最初の I フレームをすぐ表示（DisplayImmediately）し、続きは PCR に合わせた時計に従って再生します。

実測の選局時間（選局要求から映像が出るまで）:

- BS: 0.4〜0.9 秒（チューナーの選局応答は約 190ms）
- 地デジ: 0.9〜1.4 秒（PX4 の選局応答に約 650ms かかる）
- ほかのクライアントが受信中のチャンネル（チューナー共有）: 約 0.2〜0.4 秒

## プラグイン

本体がなくても成り立つ機能は、TVTest のプラグインと同じ考え方で本体から切り離して作ります。プラグインは別の Swift モジュールで、`BonboriPluginKit` の API だけを通して本体とやり取りするので、本体の内部には触れられません（コンパイラが保証します）。

本体がプラグインに提供するもの:

- 視聴中のサービス、映像が見えているか、映像の遅延（変化は通知される）。チャンネルスキャンと番組表の取得で巡回している間は「視聴中のサービスなし」として扱う
- 再生の時計（放送の時刻軸での現在位置）と、視聴中のサービスの字幕データ、データ放送用の TS（表と文書のカルーセルと PCR。映像と音声は含まない）。どちらも映像の遅延を通って届く
- 映像の上、翻訳字幕と HUD の下に重ねるビュー。`installedPlugins` の後ろのプラグインほど手前に出る。キャプチャにも合成される（Core Animation で描けないビューは、プラグインがキャプチャ用の画像を渡す）
- 映像を画面の一部に縮小する指定、選局、音声の切り替え、音量と音声の変化の通知
- 映像にフォーカスがあるときのキー（本体より先に受け取れる）
- メニュー「プラグイン」（右クリックメニューにも出る）と、オン / オフのキー
- プラグイン専用の設定の保存先、HUD のメッセージ、デバッグログ

オン / オフの状態は本体が保存します。プラグインを追加するには、`Sources/Plugins` の下にターゲットを作り、`Package.swift` と `Sources/Bonbori/InstalledPlugins.swift` に書き加えます。削除はその逆です。プラグインが 1 つもなければ、メニュー「プラグイン」も出ません。

プラグインは実行時に読み込まず、アプリに静的にリンクしています。実行時に読み込むには API を動的ライブラリとして本体と共有し、同じコンパイラでビルドしたものを揃える必要があり、1 つのリポジトリからビルドするアプリには手間に見合わないためです。

## サーバー側の注意

- **スクランブル**: Bonbori 自体はスクランブルの解除を行いません。視聴には、サーバーから解除済みの TS が届く構成が必要です。設定の「サーバー側でスクランブル解除を要求する」をオンにすると、選局時に BonDriverProxyEx プロトコルの `eDesireToUseB25` を付けて要求します。解除されていない放送を受信すると、画面にその旨を表示します。
- **遅延をさらに短くしたいとき**: サーバー ini の `TSPACKET_BUFSIZE`（初期値 192512 = 地デジで約 90ms 分）を小さくすると、送信単位が小さくなって遅延が減ります。
- **チューナーの共有**: BonDriverProxyEx は空いているチューナーを優先して使います。ただし全部使用中で、ほかのクライアントがチャンネルロックを使っていない場合は、そのクライアントのチューナーのチャンネルを変えてしまうことがあります（サーバーの仕様）。録画ソフトは `CHANNEL_LOCK` を設定しておくと安全です。

## デバッグ

```sh
BONBORI_DEBUG=1 .build/release/Bonbori          # 選局時間・A/V の余裕・時計のずれのログ（時刻付き）を stderr に出す
                                                # 翻訳字幕の到着と、再生に間に合ったか（lead が正なら間に合った）も出す
BONBORI_DEBUG=1 BONBORI_ZAP_TEST=5 .build/release/Bonbori   # 5 秒ごとに自動でザッピングする
BONBORI_DEBUG=1 BONBORI_DRIFT_TEST=3000 .build/release/Bonbori   # 時計が 3000ppm ずれた状態を再現して、遅延の補正を確かめる
BONBORI_GUIDE=1 .build/release/Bonbori          # 起動時に番組表を開く（BONBORI_DEBUG=1 で番組表取得の各局の完了/タイムアウトも出す）
.build/release/tvprobe <サーバーのアドレス> BonDriver-T 0 4 5   # コアだけで受信テスト（space 0 / ch 4 を 5 秒）
REC=/tmp/out.ts .build/release/tvprobe <サーバーのアドレス> BonDriver-S 0 16 90 245   # 受信した TS をそのまま保存（解析用）
CAPDUMP=/tmp/cap.bin .build/release/tvprobe <サーバーのアドレス> BonDriver-T 0 4 90   # 受信した字幕データを保存（解析用）
TSDUMP=/tmp/data.ts .build/release/tvprobe <サーバーのアドレス> BonDriver-T 0 4 30   # データ放送に渡す TS を保存（解析用）
```

`BONBORI_DEBUG=1` のときは、データ放送のページのログも stderr に出て、Safari の Web インスペクタ（開発 › この Mac）からページを調べられます。

放送字幕とデータ放送のテストは次のコマンドで実行します。Command Line Tools だけの環境では、Swift Testing のマクロの場所を指定する必要があります。

```sh
TESTING=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
swift test -Xswiftc -plugin-path -Xswiftc $TESTING
# 保存した字幕データの中身を表示する（CAPTION_IMAGES を指定すると、描画結果を PNG で保存する）
CAPTION_DUMP=/tmp/cap.bin CAPTION_IMAGES=/tmp/pages swift test --filter dump -Xswiftc -plugin-path -Xswiftc $TESTING
```

旧名の `ITV_DEBUG` などの環境変数も、当面はそのまま使えます。

遅延の補正（ずれの量と補正量）と PCR の飛びによる時計のやり直しは、環境変数なしでも macOS のログに残ります（ずれの量は 10 分ごとにも記録）。
長時間再生の様子は次のコマンドで確認できます。

```sh
log show --last 1d --predicate 'subsystem == "net.ebycow.bonbori"'
```

## 未実装

- 番組表の予約・キーワード検索の保存（今は表示と選局、表示中の放送内の検索のみ）
- ハードウェアデコード（今は MPEG-2 ソフトウェアデコード＋bwdif で、地デジ視聴時は 1 コアの 20〜35%、M1 全体では数 %）

## 参考にしたもの・謝辞

- [TVTest](https://github.com/DBCTRADO/TVTest)（DBCTRADO, GPL-2.0-or-later）: 番組表の取得（チャンネル巡回と完了判定）、ジャンル名、チャンネルの並び順、番組表の操作などの動作を参考にしています。参照には、そのフォークの [tsukumijima/TVTest](https://github.com/tsukumijima/TVTest) も使っています。
- [LibISDB](https://github.com/DBCTRADO/LibISDB)（DBCTRADO, GPL-2.0-or-later）: ARIB 追加記号の文字列表記、音声タイムスタンプの許容ずれなどを参考にしています。
- [BonDriverProxyEx](https://github.com/HaijinW/BonDriverProxyEx)（MIT License）: 通信プロトコル（`inc/BdpPacket.h`）に従って実装しています。HaijinW 版は、原作の [u-n-k-n-o-w-n/BonDriverProxyEx](https://github.com/u-n-k-n-o-w-n/BonDriverProxyEx) から [tkmsst/BonDriverProxyEx](https://github.com/tkmsst/BonDriverProxyEx) を経たフォークです。
- [TVTDataBroadcastingWV2](https://github.com/otya128/TVTDataBroadcastingWV2)（otya, MIT License）: データ放送プラグインの動作と、`Web/DataBroadcasting/src/main.ts` の元になったコードを使っています。ライセンスは `Web/DataBroadcasting/LICENSE.TVTDataBroadcastingWV2` にあります。
- [web-bml](https://github.com/otya128/web-bml)（otya, MIT License）: データ放送の BML の表示はこれが行います。ビルド時に取得し、アプリに同梱します。
- [web-bml-fonts](https://www.npmjs.com/package/web-bml-fonts)（Kosugi / Kosugi Maru, Apache License 2.0）: データ放送の表示に使うフォントです。ビルド時に取得し、アプリに同梱します。
- [FFmpeg](https://ffmpeg.org/): 映像・音声のデコードとインタレース解除に使っています。
- [NicoJK](https://github.com/rutice/NicoJK)（rutice）と、そのフォークの [xtne6f/NicoJK](https://github.com/xtne6f/NicoJK)（xtne6f）: ニコニコ実況の表示の動作（行数と表示時間、コメントの配置、色の指定）を参考にしています。放送サービスと実況チャンネルの対応表は同梱の `jkch.sh.txt` から生成しています。
- [jkcnsl](https://github.com/xtne6f/jkcnsl)（xtne6f, MIT License）: NX-Jikkyo との通信手順を参考にしています。
- [NX-Jikkyo](https://github.com/tsukumijima/NX-Jikkyo)（tsukumijima, MIT License）: 実況コメントの受信に利用しています。
- [TVCaptionMod2](https://github.com/xtne6f/TVCaptionMod2)（xtne6f）と、その元になった odaru 氏の「字幕 Plugin For TVTest」、mark10als 氏・maki 氏の Caption2Ass_PCR 付属の Caption.dll 改造版: 字幕と文字スーパーの解釈と表示の動作を参考にしています。ARIB の色、追加記号の Unicode 対応表、DRCS の置き換え表は同梱の `ColorDef.h`、`GaijiTable.h`、`TVCaptionMod2_Gaiji_std.txt` から生成しています。内蔵音は同梱の `src/rom` をビルド時に取り込みます（速報チャイム1は xtne6f 氏の自作、ほかは[小森平氏のフリー効果音](https://taira-komori.jpn.org/)を加工・調整したもの。規約はアプリ内の `CaptionSounds/readme.txt` に引用されています）。
- ARIB STD-B10 / STD-B24 / TR-B14 などの規格。

## 免責事項

- Bonbori は個人のプロジェクトです。Apple、TVTest・LibISDB の作者、ARIB、各放送事業者とは関係ありません。
- 放送の受信・視聴・録画は、受信契約や著作権法などの法令の範囲で行ってください。録画した TS は私的利用の範囲で扱ってください。
- 無保証です。詳しくはライセンスを参照してください。

## ライセンス

[GNU General Public License v2.0 or later](LICENSE)（GPL-2.0-or-later）。

Homebrew の ffmpeg は GPL（v3）の構成でビルドされているため、それにリンクした Bonbori のバイナリを配布する場合は GPL v3 の条件に従う必要があります。
