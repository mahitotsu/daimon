# CLAUDE.md

このファイルは、このリポジトリで作業する AI エージェント(Claude Code 含む)向けのガイドです。ツール自体の説明・セットアップ手順・セキュリティ上の注意は README.md を参照してください。ここには、コードを変更する際に踏まえておくべき設計上の制約・既知の落とし穴・確認手順だけをまとめます。

## このリポジトリは何か(1行)

Claude Code の利用状況(トークン/コスト・ツール呼び出し傾向・セッション全文)を完全ローカルで可視化するための、シェルスクリプト+設定テンプレート+Skill 一式。単一ユーザー・単一マシン前提で、アプリケーションコードは持たない。

## リポジトリマップ

| パス | 役割 |
|---|---|
| `setup.sh` | 下記4ステップを順に呼ぶ、冪等なオーケストレーター |
| `scripts/merge-settings-env.sh` | `~/.claude/settings.json` の `env` に必要な環境変数を非破壊マージ |
| `scripts/install-alloy.sh` + `alloy/config.alloy.template` + `systemd/claude-alloy.service.template` | Alloy を自ユーザーの `systemd --user` サービスとして導入・常駐 |
| `docker/docker-compose.yml` + `docker/otelcol-metrics-overlay.yaml` | `grafana/otel-lgtm`(OTel Collector + Prometheus + Loki + Tempo + Grafana)、127.0.0.1 のみバインド。Tempo は追加設定なしで OTLP trace をそのまま受けるため trace 用オーバーレイは無い |
| `docker/grafana-dashboard-claude-code-usage.json` + `docker/grafana-dashboards-provisioning.yaml` | トークン/コスト/アクティブ時間/セッション数/ツール呼び出し頻度をまとめた「利用サマリー」ダッシュボード(uid: `claude-code-usage-summary`)を Grafana に自動プロビジョニング |
| `scripts/setup-grafana-mcp.sh` | 専用 Grafana サービスアカウントを発行し、公式 `grafana-mcp` を user スコープの MCP サーバーとして登録 |
| `.claude/skills/claude-observability/SKILL.md` | 「トークン使用量」「ツール呼び出し頻度・所要時間」「ターン/トレース構造」「セッション内容検索」の質問にどのデータソース/クエリ(Prometheus/Tempo TraceQL/Loki)で答えるかをまとめた Skill |

## 変更時に踏まえるべき設計上の制約

いずれも意図的な決定であり、一見冗長・非効率に見えても安易に「簡略化」しないこと。理由:

- **Alloy はホストネイティブ実行、Docker 化しない。** バインドマウント越しのファイル変更通知は仮想化レイヤーを挟むと遅延・欠落するリスクがあるため。
- **Alloy は apt パッケージではなく公式スタンドアロンバイナリを使う。** apt 版は専用の `alloy` システムユーザーで動く system-level systemd service になり、`~/.claude/projects` の読み取り権限を持たない。
- **otel-lgtm は Docker の `restart: unless-stopped` のみに依存する。** Alloy 側のような独自の `systemd --user` ラッパーは不要(Docker の再起動ポリシーで十分)。
- **自作 MCP サーバーは持たない。** 汎用的な Prometheus/Loki/Tempo クエリは公式 `grafana-mcp` に任せ、ドメイン固有ロジック(既知のメトリクス名/span 属性名、Loki 2ストリーム・Tempo・Prometheus の使い分けなど)だけを Skill 側に持たせる設計。ツール呼び出し頻度集計用の専用 Python スクリプトは、まず OTel `tool_result` イベント(1呼び出し1フラットイベント)による汎用 LogQL 集計で置き換えて撤去し、現在はさらに Tempo の trace export(下記)が有効になったことで、頻度・所要時間・成否集計自体を TraceQL メトリクスに寄せている(`duration`/`success` が span のネイティブ属性で `unwrap` 不要、パーセンタイルも取れるため)。Loki はペイロードサイズ(`tool_input_size_bytes`/`tool_result_size_bytes`)のバックストップ用途のみに縮退済み。復活・逆戻りさせる前に本当に必要か疑うこと。
- **トレース(ベータ)を有効化し、呼び出し系列・所要時間の集計は Tempo TraceQL に寄せる。** `CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1` + `OTEL_TRACES_EXPORTER=otlp` で `claude_code.interaction`(ターン)→ `llm_request`/`tool` → `tool.execution`/`tool.blocked_on_user` の span 階層が Tempo に届く。内容(プロンプト本文・ツール引数)は既定でリダクトされ Tempo 側にも残らないため、内容検索は引き続き JSONL tail(Loki `{job="claude-code-sessions"}`)の役割。既知の制約: (1) `tempo_traceql-metrics-instant`/`-range` は `start`/`end` が3時間を超えるクエリを拒否する(`tempo_traceql-search` にはこの上限は無い)、(2) `rootServiceName: "<root span not yet received>"` は `claude_code.interaction` がまだ閉じていない(ターン進行中)だけの正常状態であり、データ欠損ではない、(3) Agent SDK の `query()`/ACP streaming-json 経由では `interaction`/`tool` span が欠落し `llm_request` のみになる既知の不具合がある([anthropics/claude-code#53954](https://github.com/anthropics/claude-code/issues/53954)、Closed as not planned)が通常の CLI/VS Code 拡張機能の経路には影響しないと見られる。2026-07-07、v2.1.202 で `claude -p`(標準 CLI)と VS Code 拡張機能のチャットパネル両方から span 到達を実機確認済み(公式ドキュメントは同じく [Monitoring - Claude Code Docs](https://code.claude.com/docs/en/monitoring-usage))。詳細は `.claude/skills/claude-observability/SKILL.md` 参照。
- **`merge-settings-env.sh` はプレーンな `OTEL_*` と `ANT_` 接頭辞付きの `ANT_OTEL_*` の両方を設定する。** 標準 CLI(ターミナル起動)はプレーン名のみ、VS Code 拡張機能の組み込みバイナリは `ANT_OTEL_*` のみを読む(拡張のネイティブバイナリを `strings` で確認済みの未文書化挙動)。片方を削ると、その起動経路だけメトリクスが来なくなる。
- **`docker/otelcol-metrics-overlay.yaml` の `deltatocumulative` プロセッサは必須。** Claude Code は既定で Delta temporality のメトリクスを送出するが、Prometheus は Delta を拒否する(しかも otel-lgtm は Prometheus 自身のログを抑制するため、この拒否は何も設定しないと完全にサイレント)。送信側で `cumulative` を強制する方法もあるが VS Code 拡張の組み込みバイナリにはその変数の `ANT_` 版が存在しないため使えない。よって受信側(Collector)での変換が唯一の解。
- **JSONL tail(`{job="claude-code-sessions"}`)を OTel ログ(`{service_name="claude-code"}`)で代替しない。** OTel 側の `tool_result`/`user_prompt`/`assistant_response` はどのゲート変数を有効にしても設計上トランケートされる(`tool.output` は60KB/属性、プロンプト/レスポンスも上限あり、`tool_result` は既定でサイズしか持たない)。会話全文・ツール入出力の全文検索が必要な用途では JSONL tail が唯一の情報源。公式ドキュメント([Monitoring - Claude Code Docs](https://code.claude.com/docs/en/monitoring-usage)、2026-07-06 に v2.1.162 で確認)によれば `claude_code.tool_result`/`tool_decision` イベントの `tool_name`/`success`/`duration_ms`/`tool_input_size_bytes`/`tool_result_size_bytes` は追加ゲートなしで無条件付与される一方、`OTEL_LOG_TOOL_DETAILS=1` で得られる `tool_input` 等は個別値512文字・全体約4KBでトランケートされる(本ツールはこのゲートを有効にしていない)。otel-lgtm は追加設定なしで OTLP ログを Loki のネイティブエンドポイントへ転送する(2026-07-06、v2.1.201・otel-lgtm `latest` で実機確認)。

これらの技術的な検証結果(挙動確認)は Claude Code のバージョンに依存するため、上記の各項目に確認日・バージョンを添えて記録している。挙動が変わっていないか疑わしい場合はまずこのファイルの該当箇所を確認すること。

## 既知のツール上の落とし穴(grafana MCP)

公式 `grafana-mcp` の `query_loki_logs` は、LogQL に `line_format` ステージを1つでも加えると(no-op な `{{ .Line }}` でも)結果の `line` フィールドが全エントリから丸ごと消える。Loki のレスポンス形が変わった際に MCP 側の再パースが失敗していると見られる。行の長さを制限したい場合は `line_format` truncation ではなく、`!= "tool_result" != "toolUseResult"` のような負の line filter で巨大な行(ほぼ tool_use/tool_result ペイロード)を除外する。詳細なパターンは `.claude/skills/claude-observability/SKILL.md` を参照。

## 検証

アプリケーションコードは無い(シェルスクリプト+設定テンプレート+Skill)ため、伝統的なユニットテストは無い。変更を検証する場合は README.md の「検証手順」セクションを頭から実行すること(otel-lgtm コンテナの起動確認、Loki/Prometheus/Tempo のヘルスチェック、Alloy の systemd unit 確認、JSONL tail・OTel メトリクス/ログ・Tempo トレースの3経路でテストデータが実際に届くことの確認、ダッシュボードのプロビジョニング確認まで一通り含む)。

上記はインフラ疎通レベルの確認であり、`test/`はその一段上——site/index.html(想定利用シーン/5つの価値セクション)が約束した5つの利用シナリオが実際に自然言語での問いかけとして機能するかを検証する回帰テストである(README.md には出さず、この内部ディレクトリのみで管理する)。各シナリオの存在意義・確認観点は`test/SPEC.md`、実装(問いかけ文・成功基準・判定ロジック)は`test/scenario-N.sh`自身、実行は`test/run-all.sh`(`claude -p --model sonnet`で実行→`claude -p --model haiku --json-schema`で判定→`~/.local/share/claude-observability/regression-results.jsonl`に記録)。実APIコールを伴うため無人・高頻度実行は想定しておらず、以下のタイミングで手動実行すること:

- `.claude/skills/claude-observability/SKILL.md`、ダッシュボード定義(`docker/grafana-dashboard-claude-code-usage.json`)、Alloy 設定(`alloy/config.alloy.template`)のいずれかを変更した直後
- Claude Code のバージョンが上がった直後(メトリクス名・span 属性名・toolUseResult の形が変わりうるため)
- 何かが「前と違う気がする」と感じたとき

2026-07-08 の初回検証(自動化前、対話セッションでの手動実施)では、この確認自体が Alloy の非再帰グロブによるサブエージェント transcript 欠落という実装バグを発見している(修正は`alloy/config.alloy.template`に反映済み)。「動いているはず」で済ませず、実際に問いかけて確認する価値がある。

## 言語

README.md はユーザー向けドキュメントとして日本語で書かれている。コミットメッセージは英語(`git log` 参照)。README.md を編集する場合は日本語を維持し、コミットメッセージは英語で書くこと(ユーザーから別途指示がない限り)。
