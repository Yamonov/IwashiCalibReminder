# IwashiCalibReminder

<img src="App/Assets.xcassets/AppIcon.appiconset/icon-iOS-Default-1024@1x.png" width="96" height="96" alt="IwashiCalibReminder icon">

EIZO ColorEdgeの次回キャリブレーションまでの残り使用時間を表示する、macOSのメニューバーアプリです。現在のバージョンは **0.9** です。

## ダウンロード

[Releases](https://github.com/Yamonov/IwashiCalibReminder/releases)からZIPをダウンロードし、展開した `IwashiCalibReminder.app` を使用してください。配布アプリはDeveloper ID署名・Apple公証済みです。

## 対応環境と動作

- macOS Sonoma 14以降。Apple Silicon / IntelのUniversalバイナリ。
- 対象モニター: ColorNavigatorのDBに登録済みのEIZO ColorEdge CS/CGシリーズ。モニターとのUSB接続が必要です。実機確認はCS2731で行っています。通信形式が異なる機種は未対応として表示します。
- 残り時間の計算には、ColorNavigator 7に保存された調整記録と、使用時間による調整間隔が必要です。
- メニューバーの正方形グラフは、最短の残り使用時間に応じて緑・黄・赤へ変わります。100時間未満では整数時間、期限超過では「NG」を表示します。
- メニューはモニターごとにグループ化し、有効なモードの調整目標、前回の測定結果、使用時間、日時などを確認できます。複数台のグラフは左右に分割し、取得に失敗した場合は前回のグラフを薄く表示します。
- 更新は起動時・1時間ごと・手動操作。通知時間は時間または日で指定します。1日はモニター使用時間の24時間です。
- ColorNavigatorの通常画面が開いている間は、モニターへ問い合わせません。メニューバーのAgentだけの場合は取得できます。
- CNのデータベースはSwiftで直接読み取り、モニター設定や元のDBは変更しません。

残り時間は、調整間隔から調整後のモニター使用時間を引いた値です。カレンダー上の経過時間ではありません。グラフの黄色は「（調整間隔 − 通知設定時間）÷3」以下、赤は通知設定時間以下で、赤を優先します。

## アップデート

環境設定の「アップデートを確認…」から手動確認できます。「アップデートを自動的に確認」は初期値オンで、Sparkleが1日ごとに確認します。更新がある場合は、メニューの「環境設定…」の下とアイコン右下の青丸で知らせます。更新項目を選ぶとインストール画面を開きます。自動確認でダイアログを開いたり、更新を自動インストールしたりすることはありません。

配信先は[appcast](https://yamonov.github.io/IwashiCalibReminder/appcast.xml)です。更新ZIPとappcastにはEdDSA署名を付けています。Sparkle導入前の版からは、今回の配布アプリへ手動で置き換えてください。

残り時間は`CNCalibration`と使用時間周期の記録から計算します。セルフキャリブレーションやカレンダー指定の周期は、この計算には対応していません。

## ビルド

動作確認済みの開発環境はXcode 27と[公式Swift 6.4.1ツールチェーン](https://www.swift.org/install/macos/)です。XcodeプロジェクトはツールチェーンID `org.swift.641202610071a` を選択します。Swift 6言語モード、完全な並行性チェック、コンパイラ警告のエラー化を有効にしています。

`IwashiCalibReminder.xcodeproj` を開き、`IwashiCalibReminder` スキームでビルドしてください。コマンドラインからは次のように実行できます。

```sh
xcodebuild -project IwashiCalibReminder.xcodeproj \
  -scheme IwashiCalibReminder -configuration Release \
  -derivedDataPath build/DerivedData build
```

生成先は `build/DerivedData/Build/Products/Release/IwashiCalibReminder.app` です。アプリをビルドするたびに `BuildMetadata/BuildNumber.xcconfig` のビルド番号が増加します。

公開プロジェクトの署名はローカル実行用のアドホック署名です。Developer ID署名や公証に必要な認証情報は、配布する開発者が別途設定してください。アプリの更新機能に公式のSparkle 2.10.0を使用します。XcodeがSwift Packageを取得します。最低OSはアプリ本体・CLIが14.0、Sparkle内部バイナリは公式パッケージの12.0です。LevelDBライブラリやHomebrewは不要です。Sparkleのライセンスはアプリにも同梱しています。

更新・配布時にはSparkle公式の最新安定版を確認し、Xcodeの最低依存バージョンと`Package.resolved`を更新します。自分で更新配信する場合は`Config/AppInfo.plist`の配信URLと公開鍵を自分のものに変更し、秘密鍵は公開リポジトリに含めないでください。

配布用のDeveloper ID署名は、Xcodeの `Product > Archive` から `Distribute App > Developer ID` で書き出します。この書き出しによってSparkleの内部ヘルパーにも配布署名が付きます。書き出したアプリをApple公証し、公証チケットを添付してからZIP・appcastを作成してください。

## CLI

モニター情報を取得するCLIも共通ソースからビルドできます。

```sh
TOOLCHAINS=org.swift.641202610071a swift build -c release --product eizo-usage
.build/release/eizo-usage --help
```

このリポジトリには、アプリ・CLI・共通処理・アイコン・ビルド設定を収録しています。
