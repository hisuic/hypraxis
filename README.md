# Hypraxis

Hyprlandの既存ワークスペースを、プロジェクトの列（X）と作業空間の行（Y）で操作するLuaモジュールです。列は10個、行は必要に応じて増やせます。タイル配置はHyprlandに任せます。常駐プロセス、外部コマンド、ポーリングは使用しません。

## 対応環境

- Hyprland **0.56.2**のLua設定APIで動作確認しています。0.55や他のバージョンの互換性は未検証です。
- 現在のアクティブモニターを操作します。初期サポートは単一モニターです。
- 実行時の依存はHyprlandのみです。開発時のテストにはLuaとmakeを使用します。

## 導入

このリポジトリを取得し、そのルートで以下を実行します。同名のモジュールが既にある場合は内容を確認してから配置してください。

```sh
hypr_dir="${XDG_CONFIG_HOME:-$HOME/.config}/hypr"
install -d "$hypr_dir/workspace_grid"
install -m 644 workspace_grid.lua "$hypr_dir/workspace_grid.lua"
install -m 644 workspace_grid/core.lua "$hypr_dir/workspace_grid/core.lua"
install -m 644 workspace_grid/hyprland.lua "$hypr_dir/workspace_grid/hyprland.lua"
```

`hyprland.lua`をバックアップしてから、既存キーバインドの登録**より後**、デフォルトsubmapの位置に次の1行を追加します。

```lua
require("workspace_grid")
```

設定ディレクトリはHyprlandがLuaの検索パスに追加するため、`package.path`の変更は不要です。独自の`--config`を使用している場合は、その設定ファイルと同じディレクトリにモジュールを配置します。

```sh
hyprctl reload config-only
hyprctl configerrors
```

更新時も同じ3ファイルを配置し直し、リロードします。

## 操作

| キー | 操作 |
|---|---|
| Super + 1〜9 / 0 | X=1〜9 / 10の列へ移動 |
| Super + Alt + Up | 同じ列の1行上へ移動 |
| Super + Alt + Down | 同じ列の1行下へ移動 |
| Super + Shift + 1〜9 / 0 | アクティブウィンドウを対応列へ移動し、追従 |
| Super + Alt + Shift + Up / Down | アクティブウィンドウを上下の行へ移動し、追従 |

Y=1での上移動は何もしません。未訪問の列はY=1から始まり、訪問済みの列では最後のYに戻ります。同じ列への再移動も何もしません。

**上記24個のキーの既存割り当てを置き換えます。** Super + Shift + 数字も、固定IDへの移動から列の記憶位置への移動に変わります。他のキーは変更しません。0.56.2の`hl.unbind()`は同じキー表記を持つ他のsubmapの割り当ても解除するため、これらのキーを別のsubmapでも使っている設定では導入前に調整してください。モジュールを読み込んだ後に同じキーを再登録しないでください。

特殊ワークスペースを表示している間、グリッド操作は何もしません。特殊ワークスペースの既存キーはそのまま使用できます。ウィンドウのない空間と固定表示（pinned）のウィンドウではウィンドウ移動を行いません。

## 位置記憶と制約

内部では`id = x + 10 * (y - 1)`に変換します。例えば(1, 2)は11、(2, 5)は42です。既存の正のワークスペースIDもこの対応に組み込まれるため、IDが11以上の既存ワークスペースも利用されます。

行数の固定上限は設けていません。座標変換はLuaとLuaJITで整数を正確に扱えるID範囲（1〜2^53−1）を検証し、範囲外を拒否します。負のIDや特殊ワークスペースは記憶しません。

ワークスペース変更・モニターフォーカス・起動・リロードのイベントで同期し、操作直前にも現在位置を確認します。ジェスチャー、マウス、`hyprctl`などによる外部切り替えも記憶します。

記憶はLuaセッション内のみです。**0.56.2では設定リロードでLua状態と登録ハンドラが破棄されるため、他の列の記憶はリセットされ、現在のワークスペースの位置だけを再取得します。** 同じLuaセッションでの再読み込みは登録を重複させません。再起動後の永続化は実装していません。

マルチモニターでは列の記憶を共有し、切り替え先をアクティブモニターに表示するHyprland標準の処理を使います。モニターごとの独立したグリッド、表示中の別モニターとの競合、ホットプラグの動作は未検証です。

## Luaからの操作

```lua
local grid = require("workspace_grid")
grid.switch_column(2)
grid.step(1)                     -- 下へ
grid.move_to_column(3)           -- 移動して追従
grid.move_vertical(-1, false)    -- ウィンドウだけ上へ移動
local x, y = grid.position()
```

操作は成功時に`true`、境界・無効な状態・失敗時に`nil, reason`を返します。`position()`は`x, y`または`nil, reason`を返します。Hyprlandの移動に失敗した場合、移動先を記憶に書き込みません。

座標変換は`require("workspace_grid.core").to_id(x, y)`と`from_id(id)`で独立して利用できます。コアの省略可能な第3引数（`from_id`では第2引数）で列数を指定できますが、標準キーバインドとHyprland連携は10列です。

## 削除

`hyprland.lua`から`require("workspace_grid")`の1行を削除し、`hyprctl reload config-only`を実行します。元の設定にあるキーバインドが復活します。その後、導入した`workspace_grid.lua`と`workspace_grid/`を削除します。ワークスペースやウィンドウを削除する処理はありません。

## 開発と検証

```sh
make test
make test LUA=luajit
```

テストは通常のLuaで実行できます。座標と境界、独立した列の記憶、外部イベント、失敗時の整合性、特殊ワークスペース、ウィンドウ移動、キーバインドの競合、再登録を検証します。Hyprland連携部分はAPIのモックを使用します。

実機では設定エラー、列・行の切り替え、テスト用ウィンドウの移動、対象外キーの保持、リロード後の重複登録、既存ウィンドウの保持を確認します。物理キー入力と複数モニターの検証は別途必要です。

APIはインストール済みLua stubと[Hyprland v0.56.2のソース](https://github.com/hyprwm/Hyprland/tree/v0.56.2/src/config/lua)を基準にしています。[公式キー設定](https://wiki.hypr.land/configuring/core/binds/)と[公式イベント一覧](https://wiki.hypr.land/configuring/core/advanced-configuration/events/)は最新開発版を扱う場合があるため、使用するバージョンのstubと照合してください。

個人設定、調査ログ、絶対パス、認証情報をリポジトリに追加しないでください。ローカル専用の`PROMPT.md`と`docs/`はGitの除外対象として扱います。

## ライセンス

選定待ちです。`LICENSE`は選定後に追加します。
