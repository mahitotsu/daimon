# Claude Code ローカル自己観測ソリューション

Claude Code の利用状況(トークン使用量・コスト・ツール呼び出し傾向・セッション内容)を、強制ではなく任意機能としてローカルに可視化し、MCP 経由で自然言語から自己利用できるようにするツール一式。

- **完全ローカル完結・単一ユーザー前提**。マルチテナント統制、Kubernetes オーケストレーション、強制計装化、クラウドへの転送・長期保管、改ざん検知のクロスチェックは非スコープ。
- テレメトリは Claude Code の任意機能であり、本ツールはそれを可視化するだけ。有効化・無効化はいつでも `~/.claude/settings.json` の `env` で切り替えられる。
- **対象環境**: Linux(WSL2 含む)かつ `systemd --user` が使えること。Alloy を `systemd --user` サービスとして常駐させる設計のため、systemd 以外の init や `systemd --user` が無効な環境では動かない。WSL2 の場合は追加で `docker.service` が systemd 管理下で有効化されていること(`otel-lgtm` コンテナの自動起動に必要)。

**セキュリティ/プライバシー上の注意**: Claude Code の公式テレメトリは `OTEL_LOG_USER_PROMPTS` / `OTEL_LOG_TOOL_DETAILS` / `OTEL_LOG_TOOL_CONTENT` を既定 OFF にすることで、ユーザープロンプト・ツール引数・実行結果本体が外部に出ないようガードしている。本ツールは Alloy 経由で `~/.claude/projects/*.jsonl`(会話全文・ツール引数・実行結果に相当する内容を含む)を直接 Loki に再保存するため、**この公式ガードを実質バイパスする設計である**。暗号化なし・保存期間無制限(手動削除のみ)で、単一ユーザーのローカル環境での自己観測用途を前提にしている。顧客データや機密情報が混在しうる会社貸与 PC・共有環境では、Loki に再保存された全文がホストの他プロセス/他ユーザーから読める状態になるため導入を推奨しない。

上記の「既定 OFF ガード」は会話内容・ツール引数/結果の**中身**にのみ適用される点に注意。`user_email` / `user_account_id` / `user_account_uuid` / `organization_id` / ハッシュ済み `user_id` などの識別情報は、追加のゲート変数を何も設定しなくても、テレメトリを有効化した時点で全イベント(メトリクス・ログ双方)に無条件で付与される(2026-07-06、Claude Code v2.1.201 で実測確認)。単一ユーザー・単一組織のローカル利用が前提の本ツールでは実害は小さいが、「公式テレメトリは既定で何も漏らさない」という理解は正確ではない。

## アーキテクチャ

| コンポーネント | 役割 |
|---|---|
| `docker/docker-compose.yml` + `docker/otelcol-metrics-overlay.yaml` | `grafana/otel-lgtm`(OTel Collector + Prometheus + Loki + Tempo + Grafana)を Docker で常駐。Claude Code の OTel メトリクスの受け口。127.0.0.1 のみにバインド。 |
| `scripts/merge-settings-env.sh` | `~/.claude/settings.json` の `env` に、テレメトリ有効化に必要な環境変数を非破壊マージ。 |
| `scripts/install-alloy.sh` + `alloy/config.alloy.template` + `systemd/claude-alloy.service.template` | Grafana Alloy をスタンドアロンバイナリとして `~/.local/bin` に導入し、**自分のユーザーの** `systemd --user` サービスとして常駐させ、`~/.claude/projects/*/*.jsonl` を tail して Loki(`{job="claude-code-sessions"}`)に push する。会話全文・ツール実行結果本体はトランケートなしで欲しいため、この経路で取得する(OTel 側にも構造化イベントはあるが、トランケートされたメタデータ止まり。詳細は下記「設定リファレンス」参照)。 |
| `scripts/setup-grafana-mcp.sh` | 公式 `grafana/mcp-grafana`(`uvx` 経由)を、専用の Grafana サービスアカウント/トークンを発行した上で MCP サーバーとして登録する。Prometheus/Loki への汎用クエリ(`query_prometheus` / `query_loki_logs` 等)を提供。 |
| `.claude/skills/claude-observability/` | 「トークン使用量」「ツール呼び出し頻度」「セッション内容検索」を聞かれた際の回答手順をまとめた Skill。`SKILL.md` に、既知のメトリクス名・PromQL/LogQL の型と、2つの Loki ストリーム(`{job="claude-code-sessions"}` = JSONL 全文、`{service_name="claude-code"}` = OTel ログイベント)の使い分けを持つ。ツール呼び出し頻度は OTel の `tool_result` イベントが1呼び出し1フラットイベントなので汎用 LogQL 集計で足り、専用スクリプトは持たない。 |
| `setup.sh` | 上記すべてを束ねる冪等なセットアップスクリプト。 |

**設計上の注意点**:
- Alloy は Docker コンテナ化していない。バインドマウント越しのファイル変更通知は仮想化レイヤーを挟むと遅延・欠落するリスクがあるため、ホストネイティブに実行する。
- Alloy は apt パッケージではなく公式スタンドアロンバイナリを使う。apt 版は専用の `alloy` システムユーザーで動く system-level systemd service になり、`~/.claude/projects` の読み取り権限を持たないため。
- otel-lgtm の常駐は `docker-compose.yml` の `restart: unless-stopped` のみに依存する(WSL2 の `docker.service` が systemd で有効化されている前提)。Alloy 側のような独自の `systemd --user` ラッパーは Docker には不要。
- otel-lgtm のランタイムデータ(Prometheus TSDB・Loki チャンク・Grafana の状態、コンテナ内 root 所有)は `~/.local/share/claude-observability/otel-lgtm-data` に永続化する。生成物であってソースではないため、リポジトリの外(Alloy の状態が `~/.local/state/alloy` にあるのと同じ考え方)に置く。
- 自作 MCP サーバーは持たない。汎用クエリは公式 `grafana-mcp` に任せ、スキル側にはドメイン固有ロジック(既知のメトリクス名・2つの Loki ストリームの使い分けなど)だけを持たせる。以前はツール呼び出し頻度の集計に専用 Python スクリプトを同梱していたが、OTel の `tool_result` イベント(1呼び出し1フラットイベント)を使えば `sum by (tool_name) (count_over_time(...))` のような汎用 LogQL だけで足りると判明したため撤去した(下記「設定リファレンス」参照)。

## セットアップ

```bash
./setup.sh
```

再実行しても安全(各ステップが既存状態を検知してスキップ/上書きしない)。実行後、**Claude Code を再起動**して新しい環境変数と MCP サーバーを反映させること。

`systemd --user`(Alloy)はログインセッションが1つも無い状態が続くと停止する。これをやらないと、ターミナル/VS Code を全て閉じてログアウトした瞬間に Alloy が停止し、その間の JSONL 更新(セッション内容)が Loki に反映されない欠測期間が発生する(次にログインしてセッションが開始されれば Alloy は再度起動し、tail は再開するが、欠測していた期間分は失われる)。バックグラウンドでも収集を継続したい場合は、別途 `sudo loginctl enable-linger $(whoami)` を実行すること(root 権限が必要なため `setup.sh` は自動実行しない)。

## 設定リファレンス

`~/.claude/settings.json` の `env` に設定する値(`merge-settings-env.sh` が書き込む最小限のセット):

| キー | 値 | 理由 |
|---|---|---|
| `CLAUDE_CODE_ENABLE_TELEMETRY` | `1` | テレメトリの有効化フラグ |
| `OTEL_METRICS_EXPORTER` | `otlp` | 標準 CLI(ターミナルから直接 `claude`)向け |
| `OTEL_LOGS_EXPORTER` | `otlp` | 同上。`tool_result`/`tool_decision` イベント(ツール呼び出し頻度・成否・所要時間の集計用)の送出に必要 |
| `OTEL_EXPORTER_OTLP_PROTOCOL` | `grpc` | 同上 |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://localhost:4317` | 同上(otel-lgtm の OTLP gRPC ポート) |
| `ANT_OTEL_METRICS_EXPORTER` | `otlp` | VS Code 拡張機能の組み込みバイナリ向け(下記参照) |
| `ANT_OTEL_LOGS_EXPORTER` | `otlp` | 同上 |
| `ANT_OTEL_EXPORTER_OTLP_PROTOCOL` | `grpc` | 同上 |
| `ANT_OTEL_EXPORTER_OTLP_ENDPOINT` | `http://localhost:4317` | 同上 |

**プレーン名と `ANT_` 接頭辞名の両方が必要な理由**: VS Code 拡張機能配下で起動される Claude Code の組み込みバイナリは、標準の `OTEL_*` 環境変数を無視し、代わりに `ANT_OTEL_*` という1:1で対応する接頭辞付き変数のみを読む(拡張の `native-binary/claude` を `strings` で確認済み)。ターミナルから直接起動する標準 CLI は逆にプレーン名のみを読む。両方の起動経路をサポートするため両方を設定する。この挙動は公式ドキュメントに明記されておらず VS Code 拡張のバイナリ内部の未文書化仕様に依存しているため、拡張の将来のアップデートで変わっても気づきにくい。**壊れた場合の兆候**: 片方の起動経路(VS Code 拡張 or ターミナル CLI)だけメトリクスが Prometheus に来なくなる。両方の経路で操作した後 `claude_code_token_usage_tokens_total` に差分が出るか確認すると切り分けられる。

**OTel の *ログ* エクスポート(`OTEL_LOGS_EXPORTER`)は有効化し、集計専用に使う**: 公式ドキュメント([Monitoring - Claude Code Docs](https://code.claude.com/docs/en/monitoring-usage)、2026-07-06 に Claude Code v2.1.162 で確認)によれば、OTel には `claude_code.tool_result` / `claude_code.tool_decision` イベントが存在し、`tool_name`/`success`/`duration_ms`/`tool_input_size_bytes`/`tool_result_size_bytes` などが**追加のゲート変数なしで**無条件に付与される。`OTEL_LOG_TOOL_DETAILS=1` を有効にするとさらに `tool_parameters`(Bash なら `bash_command`/`full_command`/`git_commit_id`、MCP なら `mcp_server_name`/`mcp_tool_name` など)と `tool_input`(ツール引数の JSON、個別値512文字・全体約4KBでトランケート)が付与されるが、本ツールはこのゲートを有効にしていない(頻度・成否・所要時間の集計に必要な属性は既定で足りるため)。

otel-lgtm はデフォルトで OTLP ログ受信 → Loki のネイティブ OTLP エンドポイントへの経路を持っており、追加のコレクター設定なしでそのまま届く(2026-07-06、Claude Code v2.1.201・otel-lgtm `latest` で実機確認: `{service_name="claude-code"} | event_name="tool_result"` で取得可能)。`tool_name` などは Loki の構造化メタデータとして入るため、`sum by (tool_name) (count_over_time({service_name="claude-code"} | event_name="tool_result" [24h]))` のような素の LogQL で集計できる。これにより、以前 `scripts/tool_usage.py` が JSONL の `tool_use` ブロック(1メッセージに複数個が配列で埋め込まれる)を自前でパースしていた処理が不要になったため、このスクリプトは撤去した。

それでも JSONL tail は別途維持している。以下は OTel 側では常にトランケートされる設計だから:
- `tool_result` イベントは実行結果そのものではなく `tool_result_size_bytes`(サイズ)しか持たない。実行結果の中身を見るには `CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1` でトレーシングを有効にした上で `OTEL_LOG_TOOL_CONTENT=1` を追加設定し、`claude_code.tool` スパンの `tool.output` スパンイベントを見る必要があるが、これも **60KB/属性でトランケート**される。
- `user_prompt` イベントは既定で `prompt: "<REDACTED>"` になり、`OTEL_LOG_USER_PROMPTS=1` で解除できるが、こちらも無制限ではない(`assistant_response` 側は `OTEL_LOG_ASSISTANT_RESPONSES` で 60KB 制限)。
- 会話全文・ツール実行結果本体を欠損なく検索したい用途では、これらのトランケート済みメタデータでは情報量が足りない。JSONL は元データをそのまま持つため全文検索に使える。

つまり「集計」と「全文検索」で必要な経路を分けている: 頻度・コスト・成否・所要時間の集計は OTel(`{service_name="claude-code"}`)に寄せ、会話全文・ツール入出力の全文検索だけを JSONL tail(`{job="claude-code-sessions"}`)に残す。技術的な検証結果は Claude Code のバージョンで変わりうるため、確認日・バージョンを添えて記録する運用とする。

**メトリクスの temporality(Delta/Cumulative)は送信側で設定しない**: Claude Code は既定で Delta temporality のメトリクスを送出するが、Prometheus は Delta を受け付けず `invalid temporality and type combination for metric ...` として拒否する(`otel-lgtm` は既定で Prometheus 自身のログを抑制するため、この拒否は何も設定しなければ完全にサイレント)。`OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=cumulative` で送信側から強制する方法もあるが、VS Code 拡張機能の組み込みバイナリにはこの変数の `ANT_` 版が存在せず強制できない。そのため送信側ではなく **受信側の OTel Collector** で解決する: `docker/otelcol-metrics-overlay.yaml` がメトリクスパイプラインに `deltatocumulative` プロセッサ(`otelcol-contrib` 同梱)を追加し、Delta を Cumulative に変換してから Prometheus に渡す。送信側がどちらの temporality で送ってきても機能する。

## 検証手順

1. `docker ps` — `claude-otel-lgtm` コンテナが Up していること。
2. `curl -s localhost:3100/ready` / `curl -s localhost:9090/-/healthy` — Loki / Prometheus が応答すること。
3. `systemctl --user status claude-alloy` — active (running) であること。
4. Claude Code で何か操作した後 60〜120 秒待ち、`curl -s 'localhost:9090/api/v1/query' --data-urlencode 'query=claude_code_token_usage_tokens_total'` で実データが返ることを確認する。
5. `curl -s 'localhost:3100/loki/api/v1/query_range' --data-urlencode 'query={job="claude-code-sessions"}'` — セッション JSONL の行が取り込まれていること。
6. `curl -sG 'localhost:3100/loki/api/v1/query' --data-urlencode 'query={service_name="claude-code"} | event_name="tool_result"' --data-urlencode "time=$(date +%s)"` — OTel の `tool_result` ログイベントが取り込まれていること(空なら、直前にツールを1回以上使ってから60〜120秒待つ)。
7. `claude mcp list` — `grafana` が Connected であること。
8. Claude Code から自然言語で「直近のセッションでどのツールを多く使った?」「今のトークン使用量は?」等を尋ね、`grafana` MCP のツールや `claude-observability` スキルが呼ばれ妥当な応答が返ることを確認する。新しく登録した MCP サーバー/スキルは **次回のセッション開始時から** 有効になる(登録した当のセッション内では使えない)。

## アンインストール

```bash
systemctl --user disable --now claude-alloy
rm ~/.config/systemd/user/claude-alloy.service ~/.config/alloy/config.alloy ~/.local/bin/alloy
docker compose -f docker/docker-compose.yml down   # 停止のみ。データは ~/.local/share/claude-observability/otel-lgtm-data に残る
rm -rf ~/.local/share/claude-observability            # データも削除する場合
claude mcp remove grafana -s user
```

`~/.claude/settings.json` の `env` に追加されたキー(上記「設定リファレンス」の9つ)は手動で削除する(`merge-settings-env.sh` は非破壊マージのみを行い、アンインストール操作は提供しない)。Grafana 側に作成したサービスアカウント(`claude-code-mcp`)は Grafana UI の Administration > Service accounts から削除できる。
