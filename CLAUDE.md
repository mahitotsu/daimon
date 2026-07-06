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
| `docker/docker-compose.yml` + `docker/otelcol-metrics-overlay.yaml` | `grafana/otel-lgtm`(OTel Collector + Prometheus + Loki + Tempo + Grafana)、127.0.0.1 のみバインド |
| `scripts/setup-grafana-mcp.sh` | 専用 Grafana サービスアカウントを発行し、公式 `grafana-mcp` を user スコープの MCP サーバーとして登録 |
| `.claude/skills/claude-observability/SKILL.md` | 「トークン使用量」「ツール呼び出し頻度」「セッション内容検索」の質問にどのデータソース/クエリで答えるかをまとめた Skill |

## 変更時に踏まえるべき設計上の制約

いずれも意図的な決定であり、一見冗長・非効率に見えても安易に「簡略化」しないこと。理由:

- **Alloy はホストネイティブ実行、Docker 化しない。** バインドマウント越しのファイル変更通知は仮想化レイヤーを挟むと遅延・欠落するリスクがあるため。
- **Alloy は apt パッケージではなく公式スタンドアロンバイナリを使う。** apt 版は専用の `alloy` システムユーザーで動く system-level systemd service になり、`~/.claude/projects` の読み取り権限を持たない。
- **otel-lgtm は Docker の `restart: unless-stopped` のみに依存する。** Alloy 側のような独自の `systemd --user` ラッパーは不要(Docker の再起動ポリシーで十分)。
- **自作 MCP サーバーは持たない。** 汎用的な Prometheus/Loki クエリは公式 `grafana-mcp` に任せ、ドメイン固有ロジック(既知のメトリクス名、2つの Loki ストリームの使い分けなど)だけを Skill 側に持たせる設計。ツール呼び出し頻度集計用の専用 Python スクリプトも、OTel の `tool_result` イベント(1呼び出し1フラットイベント)だけで汎用 LogQL 集計が足りると判明したため撤去済み — 復活させる前に本当に必要か疑うこと。
- **`merge-settings-env.sh` はプレーンな `OTEL_*` と `ANT_` 接頭辞付きの `ANT_OTEL_*` の両方を設定する。** 標準 CLI(ターミナル起動)はプレーン名のみ、VS Code 拡張機能の組み込みバイナリは `ANT_OTEL_*` のみを読む(拡張のネイティブバイナリを `strings` で確認済みの未文書化挙動)。片方を削ると、その起動経路だけメトリクスが来なくなる。
- **`docker/otelcol-metrics-overlay.yaml` の `deltatocumulative` プロセッサは必須。** Claude Code は既定で Delta temporality のメトリクスを送出するが、Prometheus は Delta を拒否する(しかも otel-lgtm は Prometheus 自身のログを抑制するため、この拒否は何も設定しないと完全にサイレント)。送信側で `cumulative` を強制する方法もあるが VS Code 拡張の組み込みバイナリにはその変数の `ANT_` 版が存在しないため使えない。よって受信側(Collector)での変換が唯一の解。
- **JSONL tail(`{job="claude-code-sessions"}`)を OTel ログ(`{service_name="claude-code"}`)で代替しない。** OTel 側の `tool_result`/`user_prompt`/`assistant_response` はどのゲート変数を有効にしても設計上トランケートされる(`tool.output` は60KB/属性、プロンプト/レスポンスも上限あり、`tool_result` は既定でサイズしか持たない)。会話全文・ツール入出力の全文検索が必要な用途では JSONL tail が唯一の情報源。

これらの技術的な検証結果(挙動確認)は Claude Code のバージョンに依存するため、README.md では確認日・バージョンを添えて記録している。挙動が変わっていないか疑わしい場合はまずそちらを確認すること。

## 既知のツール上の落とし穴(grafana MCP)

公式 `grafana-mcp` の `query_loki_logs` は、LogQL に `line_format` ステージを1つでも加えると(no-op な `{{ .Line }}` でも)結果の `line` フィールドが全エントリから丸ごと消える。Loki のレスポンス形が変わった際に MCP 側の再パースが失敗していると見られる。行の長さを制限したい場合は `line_format` truncation ではなく、`!= "tool_result" != "toolUseResult"` のような負の line filter で巨大な行(ほぼ tool_use/tool_result ペイロード)を除外する。詳細なパターンは `.claude/skills/claude-observability/SKILL.md` を参照。

## 検証

自動テストスイートはない(シェルスクリプト+設定テンプレート+Skill であり、アプリケーションコードではないため)。変更を検証する場合は README.md の「検証手順」セクションを頭から実行すること(otel-lgtm コンテナの起動確認、Loki/Prometheus のヘルスチェック、Alloy の systemd unit 確認、両方の計装経路でテストデータが実際に届くことの確認まで一通り含む)。

## 言語

README.md はユーザー向けドキュメントとして日本語で書かれている。コミットメッセージは英語(`git log` 参照)。README.md を編集する場合は日本語を維持し、コミットメッセージは英語で書くこと(ユーザーから別途指示がない限り)。
