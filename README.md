# Claude Code ローカル自己観測ソリューション

Claude Code の利用状況(トークン使用量・コスト・ツール呼び出し傾向・セッション内容)を、強制ではなく任意機能としてローカルに可視化し、MCP 経由で自然言語から自己利用できるようにするツール一式。

- **完全ローカル完結・単一ユーザー前提**。マルチテナント統制、Kubernetes オーケストレーション、強制計装化、クラウドへの転送・長期保管、改ざん検知のクロスチェックは非スコープ。
- テレメトリは Claude Code の任意機能であり、本ツールはそれを可視化するだけ。有効化・無効化はいつでも `~/.claude/settings.json` の `env` で切り替えられる。

## アーキテクチャ

| コンポーネント | 役割 |
|---|---|
| `docker/docker-compose.yml` + `docker/otelcol-metrics-overlay.yaml` | `grafana/otel-lgtm`(OTel Collector + Prometheus + Loki + Tempo + Grafana)を Docker で常駐。Claude Code の OTel メトリクスの受け口。127.0.0.1 のみにバインド。 |
| `scripts/merge-settings-env.sh` | `~/.claude/settings.json` の `env` に、テレメトリ有効化に必要な環境変数を非破壊マージ。 |
| `scripts/install-alloy.sh` + `alloy/config.alloy.template` + `systemd/claude-alloy.service.template` | Grafana Alloy をスタンドアロンバイナリとして `~/.local/bin` に導入し、**自分のユーザーの** `systemd --user` サービスとして常駐させ、`~/.claude/projects/*/*.jsonl` を tail して Loki に push する。ツール呼び出し詳細・会話内容は OTel には出てこないため、この経路でのみ取得できる。 |
| `scripts/setup-grafana-mcp.sh` | 公式 `grafana/mcp-grafana`(`uvx` 経由)を、専用の Grafana サービスアカウント/トークンを発行した上で MCP サーバーとして登録する。Prometheus/Loki への汎用クエリ(`query_prometheus` / `query_loki_logs` 等)を提供。 |
| `.claude/skills/claude-observability/` | 「トークン使用量」「ツール呼び出し頻度」「セッション内容検索」を聞かれた際の回答手順をまとめた Skill。既知のメトリクス名・PromQL/LogQL の型を `SKILL.md` に、Loki 生ログを `tool_use` ブロック単位で集計するロジック(汎用 MCP ツールには無い処理)を `scripts/tool_usage.py` に持つ。 |
| `setup.sh` | 上記すべてを束ねる冪等なセットアップスクリプト。 |

**設計上の注意点**:
- Alloy は Docker コンテナ化していない。バインドマウント越しのファイル変更通知は仮想化レイヤーを挟むと遅延・欠落するリスクがあるため、ホストネイティブに実行する。
- Alloy は apt パッケージではなく公式スタンドアロンバイナリを使う。apt 版は専用の `alloy` システムユーザーで動く system-level systemd service になり、`~/.claude/projects` の読み取り権限を持たないため。
- otel-lgtm の常駐は `docker-compose.yml` の `restart: unless-stopped` のみに依存する(WSL2 の `docker.service` が systemd で有効化されている前提)。Alloy 側のような独自の `systemd --user` ラッパーは Docker には不要。
- otel-lgtm のランタイムデータ(Prometheus TSDB・Loki チャンク・Grafana の状態、コンテナ内 root 所有)は `~/.local/share/claude-observability/otel-lgtm-data` に永続化する。生成物であってソースではないため、リポジトリの外(Alloy の状態が `~/.local/state/alloy` にあるのと同じ考え方)に置く。
- 自作 MCP サーバーは持たない。汎用クエリは公式 `grafana-mcp` に任せ、JSONL の `tool_use` 集計のような「汎用ツールにはないドメイン固有ロジック」だけをスキル同梱のスクリプトとして残す。

## セットアップ

```bash
./setup.sh
```

再実行しても安全(各ステップが既存状態を検知してスキップ/上書きしない)。実行後、**Claude Code を再起動**して新しい環境変数と MCP サーバーを反映させること。

`systemd --user`(Alloy)はログインセッションが1つも無い状態が続くと停止する。バックグラウンドでも収集を継続したい場合は、別途 `sudo loginctl enable-linger $(whoami)` を実行すること(root 権限が必要なため `setup.sh` は自動実行しない)。

## 設定リファレンス

`~/.claude/settings.json` の `env` に設定する値(`merge-settings-env.sh` が書き込む最小限のセット):

| キー | 値 | 理由 |
|---|---|---|
| `CLAUDE_CODE_ENABLE_TELEMETRY` | `1` | テレメトリの有効化フラグ |
| `OTEL_METRICS_EXPORTER` | `otlp` | 標準 CLI(ターミナルから直接 `claude`)向け |
| `OTEL_EXPORTER_OTLP_PROTOCOL` | `grpc` | 同上 |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://localhost:4317` | 同上(otel-lgtm の OTLP gRPC ポート) |
| `ANT_OTEL_METRICS_EXPORTER` | `otlp` | VS Code 拡張機能の組み込みバイナリ向け(下記参照) |
| `ANT_OTEL_EXPORTER_OTLP_PROTOCOL` | `grpc` | 同上 |
| `ANT_OTEL_EXPORTER_OTLP_ENDPOINT` | `http://localhost:4317` | 同上 |

**プレーン名と `ANT_` 接頭辞名の両方が必要な理由**: VS Code 拡張機能配下で起動される Claude Code の組み込みバイナリは、標準の `OTEL_*` 環境変数を無視し、代わりに `ANT_OTEL_*` という1:1で対応する接頭辞付き変数のみを読む(拡張の `native-binary/claude` を `strings` で確認済み)。ターミナルから直接起動する標準 CLI は逆にプレーン名のみを読む。両方の起動経路をサポートするため両方を設定する。

**OTel の *ログ* エクスポート(`OTEL_LOGS_EXPORTER`)は意図的に設定しない**: ツール呼び出し詳細・セッション内容は Alloy が `~/.claude/projects` の JSONL を直接 tail する経路で全量取得できており、OTel ログは追加する情報量に対して割に合わない。実際に有効化して中身を確認した結果:
- `tool_decision` イベントには `tool_name`(例: `Bash`)と `decision`(`accept`/`reject`)しか入らず、実行したコマンド・引数・出力は含まれない。
- `user_prompt` イベントは既定で `prompt: "<REDACTED>"` と伏字になる。実際のプロンプト文字列を出すには `OTEL_LOG_USER_PROMPTS=1` の追加有効化が必要(既定 OFF で、センシティブな入力を OTLP 経由で外部に出すことになるため)。
- `tool_result`(ツールの実行結果本体)に相当するイベント自体が見当たらない。

つまり `OTEL_LOG_USER_PROMPTS` / `OTEL_LOG_TOOL_DETAILS` / `OTEL_LOG_TOOL_CONTENT` などを追加で有効化しても、得られるのは構造化されたイベントメタデータ止まりで、JSONL が持つ会話全文・ツール呼び出しの引数・実行結果には情報量で及ばない。既定で無効なリダクションを自ら外す代わりに、JSONL 側から取得する現在の設計を維持する。

**メトリクスの temporality(Delta/Cumulative)は送信側で設定しない**: Claude Code は既定で Delta temporality のメトリクスを送出するが、Prometheus は Delta を受け付けず `invalid temporality and type combination for metric ...` として拒否する(`otel-lgtm` は既定で Prometheus 自身のログを抑制するため、この拒否は何も設定しなければ完全にサイレント)。`OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=cumulative` で送信側から強制する方法もあるが、VS Code 拡張機能の組み込みバイナリにはこの変数の `ANT_` 版が存在せず強制できない。そのため送信側ではなく **受信側の OTel Collector** で解決する: `docker/otelcol-metrics-overlay.yaml` がメトリクスパイプラインに `deltatocumulative` プロセッサ(`otelcol-contrib` 同梱)を追加し、Delta を Cumulative に変換してから Prometheus に渡す。送信側がどちらの temporality で送ってきても機能する。

## 検証手順

1. `docker ps` — `claude-otel-lgtm` コンテナが Up していること。
2. `curl -s localhost:3100/ready` / `curl -s localhost:9090/-/healthy` — Loki / Prometheus が応答すること。
3. `systemctl --user status claude-alloy` — active (running) であること。
4. Claude Code で何か操作した後 60〜120 秒待ち、`curl -s 'localhost:9090/api/v1/query' --data-urlencode 'query=claude_code_token_usage_tokens_total'` で実データが返ることを確認する。
5. `curl -s 'localhost:3100/loki/api/v1/query_range' --data-urlencode 'query={job="claude-code-sessions"}'` — セッション JSONL の行が取り込まれていること。
6. `claude mcp list` — `grafana` が Connected であること。
7. Claude Code から自然言語で「直近のセッションでどのツールを多く使った?」「今のトークン使用量は?」等を尋ね、`grafana` MCP のツールや `claude-observability` スキルが呼ばれ妥当な応答が返ることを確認する。新しく登録した MCP サーバー/スキルは **次回のセッション開始時から** 有効になる(登録した当のセッション内では使えない)。

## アンインストール

```bash
systemctl --user disable --now claude-alloy
rm ~/.config/systemd/user/claude-alloy.service ~/.config/alloy/config.alloy ~/.local/bin/alloy
docker compose -f docker/docker-compose.yml down   # 停止のみ。データは ~/.local/share/claude-observability/otel-lgtm-data に残る
rm -rf ~/.local/share/claude-observability            # データも削除する場合
claude mcp remove grafana -s user
```

`~/.claude/settings.json` の `env` に追加されたキー(上記「設定リファレンス」の7つ)は手動で削除する(`merge-settings-env.sh` は非破壊マージのみを行い、アンインストール操作は提供しない)。Grafana 側に作成したサービスアカウント(`claude-code-mcp`)は Grafana UI の Administration > Service accounts から削除できる。
