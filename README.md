# IwashiCalibReminder

<img src="App/Assets.xcassets/AppIcon.appiconset/icon-iOS-Default-1024@1x.png" width="96" height="96" alt="IwashiCalibReminder icon">

EIZO ColorEdgeの次回キャリブレーションまでの残り時間を表示する、macOSのメニューバーアプリです。バージョン **1.0.5**。英語・日本語に対応します。

A macOS menu bar app that shows the time remaining until the next calibration of a registered EIZO ColorEdge monitor. English and Japanese are supported.

## ダウンロード

[1.0.5のリリース](https://github.com/Yamonov/IwashiCalibReminder/releases/tag/v1.0.5)からZIPをダウンロードし、展開した`IwashiCalibReminder.app`を使用してください。配布アプリはDeveloper ID署名・Apple公証済みです。

## 対応環境と表示

- macOS Sonoma 14以降。Apple Silicon / IntelのUniversalバイナリ。
- 対象はColorNavigatorのDBに登録されたEIZO ColorEdge CS/CGシリーズ。モニターとのUSB接続が必要です。実機確認はCS2731で行っています。通信形式が異なる機種は未対応として表示します。
- 使用時間方式と日付方式に対応します。使用時間方式は、現在の累積値と前回調整時の累積値の差から計算します。予想日時には調整後の平均稼働率を使います。
- 日付方式は、前回調整後の最初の予定を期限に固定し、超過しても先送りしません。Daily、Weekly、Monthly、Quarterly、SemiAnnual、Annualを扱います。SelfCorrectionと定期検証は対象外です。
- メニューバーのグラフは最短の残り時間に応じて緑・黄・赤へ変わります。100時間未満は整数時間、超過時はNGを表示します。複数モニターは左右に分けて表示します。
- メニューにはモニター情報のカード、有効モードの設定と測定値、ICCファイル名、パスのコピー・Finder表示を用意しています。
- 取得失敗時は、再利用できる前回情報を薄く表示し、最終取得成功日時を添えます。設定変更や使用時間の逆行を確認した場合は古い値を使いません。
- 残り時間が指定した日数・時間以下になると通知します。1日は24時間として換算し、同じ調整記録への通知は繰り返しません。

## 環境設定

通知する残り時間を日／時間で指定し、「ログイン時に起動」を設定できます。起動時にmacOSの通知権限を確認し、まだ未回答の場合だけ標準の許可画面を求めます。ログイン起動・スリープ中の起動では初回待機後に求めます。拒否済みには繰り返し要求せず、環境設定に状態と通知設定へのボタンを表示します。

## 通信と更新

取得は通常起動時、処理終了から1時間ごと、手動更新、スリープ復帰後に行います。Mac・モニターのスリープ中は停止し、復帰後は15秒、ログイン起動後は30秒待ちます。復帰・ログイン時の一時的な失敗は10秒・30秒・60秒の間隔で最大3回再試行します。メニューを開くだけでは問い合わせません。ColorNavigatorの通常画面が開いている場合は取得を見送ります。Agentのみの場合は取得できますが、Agentとの完全な排他制御を保証する方式ではありません。

CNのDBはSwiftで読み取り、モニター設定や元のDBは変更しません。情報不足を推測で補完せず、取得用CLIは必要なときだけ起動します。

環境設定の「アップデートを確認」から手動確認できます。自動確認は初期値オンで、Sparkleが1日ごとに確認します。更新を検出するとメニューとメニューバーの青丸で知らせます。自動確認で更新ダイアログを開いたり、自動ダウンロード・自動インストールを行ったりしません。

配信先は[署名付きappcast](https://yamonov.github.io/IwashiCalibReminder/appcast.xml)です。更新ZIPにもEdDSA署名を付けています。Sparkle導入前の版は、配布アプリへ手動で置き換えてください。

## ビルド

Xcode 27と公式Swift 6.4.1ツールチェーンで確認しています。プロジェクトは`org.swift.641202610071a`を選択し、Swift 6言語モード・完全な並行性チェック・警告のエラー化を使用します。

`IwashiCalibReminder.xcodeproj`を開き、`IwashiCalibReminder`スキームでビルドしてください。アプリのビルドごとに`BuildMetadata/BuildNumber.xcconfig`の番号が増えます。

公開プロジェクトはローカル実行用のアドホック署名を使用します。配布にはXcodeのArchiveをDeveloper IDで書き出し、同梱CLIとSparkleの補助プログラムも含めて署名・公証を確認してください。

更新機能は公式Sparkle 2.10.0を使用します。最低OSはアプリ本体・CLIが14.0、Sparkle内部バイナリは公式の12.0です。Sparkleのライセンスをアプリにも同梱しています。LevelDBライブラリやHomebrewは不要です。

自分で更新配信する場合は、`Config/AppInfo.plist`の配信URLと公開鍵を変更し、秘密鍵をリポジトリに含めないでください。

## ローカライズ

アプリの表示文言は`Sources/ReminderSupport/Resources/Localizable.xcstrings`で管理しています。macOSのアプリ言語設定に従い、変更は再起動後に適用されます。`python3 Scripts/check-localizations.py`で翻訳と参照キーを確認できます。

## CLI

```sh
TOOLCHAINS=org.swift.641202610071a swift build -c release --product eizo-usage
.build/release/eizo-usage --help
```

CLIの出力は英語です。通常のJSONはアプリに必要な項目を返し、診断用の完全な保存記録は`--json --full-details`で取得します。`--database-only`はモニターと通信せず、保存済みのCN情報だけを読み取ります。

このリポジトリにはアプリ・CLI・共通処理・アイコン・ビルド設定を収録しています。
