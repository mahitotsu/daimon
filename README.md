# Claude Code ローカル自己観測ソリューション

Claude Code の利用状況(トークン使用量・コスト・ツール呼び出し傾向・セッション内容)を、強制ではなく任意機能としてローカルに可視化し、MCP 経由で自然言語から自己利用できるようにするツール一式。

- **完全ローカル完結・単一ユーザー前提**。マルチテナント統制、Kubernetes オーケストレーション、強制計装化、クラウドへの転送・長期保管、改ざん検知のクロスチェックは非スコープ。
- テレメトリは Claude Code の任意機能であり、本ツールはそれを可視化するだけ。有効化・無効化はいつでも `~/.claude/settings.json` の `env` で切り替えられる。
- **対象環境**: Linux(WSL2 含む)かつ `systemd --user` が使えること。Alloy を `systemd --user` サービスとして常駐させる設計のため、systemd 以外の init や `systemd --user` が無効な環境では動かない。WSL2 の場合は追加で `docker.service` が systemd 管理下で有効化されていること(`otel-lgtm` コンテナの自動起動に必要)。

## 使用例

Claude Code に日本語で「この3時間の作業の質や効率を定量と定性の両方で評価して」と尋ねると、`claude-observability` Skill が Prometheus・Loki・Tempo それぞれに問い合わせ、コミット数・トークン/コスト・ツール呼び出し頻度と所要時間・失敗率に加え、セッション内容から読み取った手戻りの兆候まで、定量表と定性コメントにまとめてチャット内で直接返す(2026-07-08、Claude Code v2.1.202 で確認)。実際の画面例は [site/index.html](site/index.html) を参照。

**セキュリティ/プライバシー上の注意**: Claude Code の公式テレメトリは既定で会話内容・ツール引数/実行結果の中身を外部に送らないが、本ツールは Alloy 経由で `~/.claude/projects/**/*.jsonl`(会話全文・ツール入出力に加え、Agent/Task サブエージェントの実行内容も含む)を直接 Loki に保存するため、**この既定ガードを実質バイパスする**。暗号化なし・保存期間無制限(手動削除のみ)。単一ユーザーのローカル自己観測用途が前提で、機密情報が混在しうる会社貸与 PC・共有環境での利用は推奨しない。また `user_email` などの識別情報は、中身とは別に、テレメトリ有効化時点で全イベントへ無条件付与される(2026-07-06, v2.1.201 で確認)ため、「公式テレメトリは既定で何も漏らさない」という理解は正確ではない。

## アーキテクチャ

| コンポーネント | 役割 |
|---|---|
| `docker/docker-compose.yml` + `docker/otelcol-metrics-overlay.yaml` | `grafana/otel-lgtm`(OTel Collector + Prometheus + Loki + Tempo + Grafana)を Docker で常駐。Claude Code の OTel メトリクス・ログ・トレース(ベータ)の受け口。127.0.0.1 のみにバインド。Tempo は追加設定なしで OTLP をそのまま受け付けるため、trace 用のオーバーレイは無い。 |
| `docker/grafana-dashboard-claude-code-usage.json` + `docker/grafana-dashboards-provisioning.yaml` | トークン消費・コスト・アクティブ時間・セッション数・ツール呼び出し頻度・ツール所要時間・直近のインタラクション(トレース一覧)をまとめた「利用サマリー」ダッシュボードを Grafana に自動プロビジョニング(uid: `claude-code-usage-summary`)。Prometheus/Loki/Tempo の3ソースをそれぞれ行(row)で区切って構成する。イメージ組み込みの `grafana-dashboards.yaml` を上書きせず、別プロバイダとして追加する形。毎回 PromQL/LogQL/TraceQL を個別に組み立てる代わりに、`claude-observability` Skill がこのダッシュボードへのリンクを返せるようにするため。 |
| `scripts/merge-settings-env.sh` | `~/.claude/settings.json` の `env` に、テレメトリ有効化に必要な環境変数を非破壊マージ。 |
| `scripts/install-alloy.sh` + `alloy/config.alloy.template` + `systemd/claude-alloy.service.template` | Grafana Alloy をスタンドアロンバイナリとして `~/.local/bin` に導入し、**自分のユーザーの** `systemd --user` サービスとして常駐させ、`~/.claude/projects/**/*.jsonl` を tail して Loki(`{job="claude-code-sessions"}`)に push する。会話全文・ツール実行結果本体はトランケートなしで欲しいため、この経路で取得する(OTel 側にも構造化イベントはあるが、トランケートされたメタデータ止まり。詳細は CLAUDE.md 参照)。グロブは非再帰の `*/*.jsonl` ではなく再帰的な `**/*.jsonl` にしている。Agent/Task サブエージェントの実行内容は `<project>/<sessionId>/subagents/agent-<taskId>.jsonl` という1階層深い場所に保存されるため、非再帰グロブだと丸ごと収集対象から漏れる(2026-07-08 に実機で確認・修正)。 |
| `scripts/setup-grafana-mcp.sh` | 公式 `grafana/mcp-grafana`(`uvx` 経由)を、専用の Grafana サービスアカウント/トークンを発行した上で MCP サーバーとして登録する。Prometheus/Loki への汎用クエリ(`query_prometheus` / `query_loki_logs` 等)を提供。 |
| `.claude/skills/claude-observability/` | 「トークン使用量」「ツール呼び出し頻度・所要時間」「ターン/トレース構造」「セッション内容検索」を聞かれた際の回答手順をまとめた Skill。`SKILL.md` に、既知のメトリクス名・span 属性名と、Prometheus(集計)・Tempo(呼び出し系列・所要時間)・Loki 2ストリーム(`{job="claude-code-sessions"}` = JSONL 全文、`{service_name="claude-code"}` = OTel ログイベント)の使い分けを持つ。専用スクリプトは持たない。 |
| `setup.sh` | 上記すべてを束ねる冪等なセットアップスクリプト。 |

otel-lgtm のランタイムデータ(Prometheus TSDB・Loki チャンク・Grafana の状態、コンテナ内 root 所有)は `~/.local/share/claude-observability/otel-lgtm-data` に永続化する。生成物であってソースではないため、リポジトリの外(Alloy の状態が `~/.local/state/alloy` にあるのと同じ考え方)に置く。

このリポジトリのコードに手を入れる場合の設計上の制約(なぜ Alloy を Docker 化しないか、なぜ自作 MCP サーバーを持たないか等)は CLAUDE.md にまとめてある。

## セットアップ

```bash
./setup.sh
```

再実行しても安全(各ステップが既存状態を検知してスキップ/上書きしない)。実行後、**Claude Code を再起動**して新しい環境変数と MCP サーバーを反映させること。

`systemd --user`(Alloy)はログインセッションが1つも無い状態が続くと停止する。これをやらないと、ターミナル/VS Code を全て閉じてログアウトした瞬間に Alloy が停止し、その間の JSONL 更新(セッション内容)が Loki に反映されない欠測期間が発生する(次にログインしてセッションが開始されれば Alloy は再度起動し、tail は再開するが、欠測していた期間分は失われる)。バックグラウンドでも収集を継続したい場合は、別途 `sudo loginctl enable-linger $(whoami)` を実行すること(root 権限が必要なため `setup.sh` は自動実行しない)。

## 設定リファレンス

`merge-settings-env.sh` が `~/.claude/settings.json` の `env` に非破壊マージする値:

| キー | 値 | 用途 |
|---|---|---|
| `CLAUDE_CODE_ENABLE_TELEMETRY` | `1` | テレメトリ有効化 |
| `CLAUDE_CODE_ENHANCED_TELEMETRY_BETA` | `1` | トレース(span)出力を有効化するベータフラグ |
| `OTEL_METRICS_EXPORTER` / `ANT_OTEL_METRICS_EXPORTER` | `otlp` | メトリクス送出 |
| `OTEL_LOGS_EXPORTER` / `ANT_OTEL_LOGS_EXPORTER` | `otlp` | ツール呼び出しログ(頻度・成否・所要時間の集計用)送出 |
| `OTEL_TRACES_EXPORTER` / `ANT_OTEL_TRACES_EXPORTER` | `otlp` | span(呼び出し系列・所要時間)送出 |
| `OTEL_EXPORTER_OTLP_PROTOCOL` / `ANT_OTEL_EXPORTER_OTLP_PROTOCOL` | `grpc` | 送信プロトコル |
| `OTEL_EXPORTER_OTLP_ENDPOINT` / `ANT_OTEL_EXPORTER_OTLP_ENDPOINT` | `http://localhost:4317` | otel-lgtm の OTLP 受け口 |

プレーン名(`OTEL_*`)は標準 CLI、`ANT_` 接頭辞(`ANT_OTEL_*`)は VS Code 拡張機能の組み込みバイナリが読む(公式ドキュメント未記載の挙動)。両方設定しないと片方の起動経路だけデータが来なくなる。

データソースの役割分担(集計は Prometheus/Tempo、全文検索は JSONL tail)は上記「アーキテクチャ」参照。各変数を選んだ理由・検証済みバージョン・既知の制約(メトリクス temporality の変換、トレースの制約など)は CLAUDE.md にまとめてある。

## 検証手順

1. `docker ps` — `claude-otel-lgtm` コンテナが Up していること。
2. `curl -s localhost:3100/ready` / `curl -s localhost:9090/-/healthy` — Loki / Prometheus が応答すること。
3. `systemctl --user status claude-alloy` — active (running) であること。
4. Claude Code で何か操作した後 60〜120 秒待ち、`curl -s 'localhost:9090/api/v1/query' --data-urlencode 'query=claude_code_token_usage_tokens_total'` で実データが返ることを確認する。
5. `curl -s 'localhost:3100/loki/api/v1/query_range' --data-urlencode 'query={job="claude-code-sessions"}'` — セッション JSONL の行が取り込まれていること。
6. `curl -sG 'localhost:3100/loki/api/v1/query' --data-urlencode 'query={service_name="claude-code"} | event_name="tool_result"' --data-urlencode "time=$(date +%s)"` — OTel の `tool_result` ログイベントが取り込まれていること(空なら、直前にツールを1回以上使ってから60〜120秒待つ)。
7. `curl -s 'localhost:3200/api/search?limit=5'` — `traces` に `rootServiceName: "claude-code"` のエントリが並ぶこと(空なら、Claude Code 再起動後にツールを使う操作を挟んでから確認する)。
8. `claude mcp list` — `grafana` が Connected であること。
9. Claude Code から自然言語で「直近のセッションでどのツールを多く使った?」「今のトークン使用量は?」等を尋ね、`grafana` MCP のツールや `claude-observability` スキルが呼ばれ妥当な応答が返ることを確認する。新しく登録した MCP サーバー/スキルは **次回のセッション開始時から** 有効になる(登録した当のセッション内では使えない)。
10. `curl -s -u admin:admin 'localhost:3000/api/search?query=Claude'` — 「Claude Code 利用サマリー」ダッシュボード(uid: `claude-code-usage-summary`)がプロビジョニングされていること。

## アンインストール

```bash
systemctl --user disable --now claude-alloy
rm ~/.config/systemd/user/claude-alloy.service ~/.config/alloy/config.alloy ~/.local/bin/alloy
docker compose -f docker/docker-compose.yml down   # 停止のみ。データは ~/.local/share/claude-observability/otel-lgtm-data に残る
rm -rf ~/.local/share/claude-observability            # データも削除する場合
claude mcp remove grafana -s user
```

`~/.claude/settings.json` の `env` に追加されたキー(上記「設定リファレンス」の12個)は手動で削除する(`merge-settings-env.sh` は非破壊マージのみを行い、アンインストール操作は提供しない)。Grafana 側に作成したサービスアカウント(`claude-code-mcp`)は Grafana UI の Administration > Service accounts から削除できる。
