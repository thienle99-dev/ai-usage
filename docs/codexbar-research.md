# Nghiên cứu source CodexBar

**Ngày:** 2026-10-12
**Nguồn:** `research/CodexBar` (steipete/CodexBar, MIT) — đọc bằng codegraph index
(3.279 files, ~119k symbols, ~268k edges) kết hợp `docs/*.md` của repo đó.
Đường dẫn trong tài liệu này tương đối từ `research/CodexBar/`.

Tài liệu này đi sâu **mức source** (module, file, symbol). Đối chiếu README-level
đã có ở [FEATURE_COMPARISON.md](FEATURE_COMPARISON.md); kiến trúc app này ở
[TECHNICAL_PLAN.md](TECHNICAL_PLAN.md).

## 1. Bản đồ module (codegraph `files` + `Sources/`)

| Target | Vai trò | File đầu mối (codegraph) |
|---|---|---|
| `Sources/CodexBarCore` | Fetch + parse mọi provider: RPC, PTY, scrape web, status polling, scanner session local, descriptor registry, config upsert | `Providers/ProviderFetchPlan.swift` (`ProviderFetchStrategy`, ~119 implementations), `Providers/Codex/*`, `Providers/Claude/*` |
| `Sources/CodexBar` | State + UI: `UsageStore`, `SettingsStore`, `StatusItemController`, menus, icon rendering, `AdaptiveRefreshPolicy`, `AgentSessionsStore` | `StatusItemController+*.swift` (hàng chục extension), `MenuBarLayout.swift` (218 symbols, 70 files dùng), `MenuBarLayoutRenderer.swift`, `UsageStore+AdaptiveRefresh.swift` |
| `Sources/CodexBarCLI` | CLI `codexbar` dùng lại fetcher của Core + config file | ~50 file `CLI*.swift` (`CLIEntry.swift`, `CLIUsageCommand.swift`, `CLICostCommand.swift`, `CLIServeCommand.swift`, `CLIGuardCommand.swift`, `CLICardsCommand.swift`, `CLIHooksCommand.swift`, `CLISessionsCommand.swift`...) |
| `Sources/CodexBarWidget` | WidgetKit extension đọc snapshot dùng chung | `CodexBarWidgetBundle.swift`, `CodexBarWidgetProvider.swift`, `BurnDownWidgetProvider.swift`, `WidgetTiles.swift`, `ProviderPager.swift` |
| `Sources/AdaptiveRefreshCore` | Chính sách refresh thuần túy (pure, dễ test) | `AdaptiveRefreshPolicyCore.swift`: `struct Input{now, lastMenuOpenAt, lastCodingActivityAt, lowPowerModeEnabled, thermalPressure}`, `Decision{delay, reason}`, `Reason{recentInteraction, codingActivity, warm, idle, longIdle, constrained}` |
| `Sources/AdaptiveReplayKit` | Replay/trace kiểm chứng chính sách Adaptive | `AdaptiveRefreshTrace.swift`, `BaselinePolicies.swift`, `AgentAwarePolicies.swift` + tests |
| Helpers | Probe chẩn đoán, watchdog PTY | `CodexBarClaudeWatchdog`, `CodexBarClaudeWebProbe`, `CodexBarCostStoreCrashProbe` |

Entry: `CodexBarApp` (SwiftUI keepalive + Settings scene) + `AppDelegate`
(status controller, Sparkle updater, notifications). Luồng dữ liệu:
Background refresh → `UsageFetcher`/probes → `UsageStore` → menu/icon/widgets.
Swift 6 strict, `Sendable` + `MainActor` (`docs/architecture.md`).

## 2. Menu bar (portable nhất cho app này)

- **Renderer icon lai:** text-only một dòng dùng **cached template image 18×18**
  (AppKit tái dùng, native highlight + display-scale); stale/high-contrast/icon
  provider/emoji/multiline thì giữ `attributedTitle`. Critter/bar có renderer riêng.
  Loading animation giới hạn FPS + trần thời gian để provider treo không redraw mãi
  (`docs/ui.md#Icon-rendering`).
- **Dim-on-fail + incident overlay:** icon dim khi refresh lỗi; incident status
  hiện chấm/badge trên icon (`docs/ui.md`, `ProviderStatusFetcher` ở Core).
- **Color-by-provider opt-in** (mặc định off), gate tương phản 2:1, tự về
  monochrome khi menu mở / stale / Increase Contrast (`docs/ui.md`,
  `docs/provider-palette.md`). Menu bar mặc định vẫn system-tinted template.
- **Merge Icons:** gộp nhiều provider thành một status item + switcher; nguồn icon
  gộp = `Current selection | Highest usage | Frontmost provider app`
  (`StatusItemController+SwitcherViews.swift`, `FrontmostProviderMonitor.swift`).
- **Token layout editor** (`MenuBarLayout.swift`, `MenuBarLayoutEditor.swift`,
  `MenuBarLayoutRenderer.swift`): preset + kéo-thả token 1–2 dòng, override
  global/per-provider. Token: `Icon, Provider name, Account | Session %, Weekly %,
  Scoped weekly %, Auto %, Usage bar | Resets in, Reset at, Runs out | Balance,
  Cost today, Cost 30d | Separator dot, Space, Line break`. Thiếu dữ liệu → `—`.
  Pace token `+11%/-8%`, `Color Pace Indicator`, `Pace sign` (`docs/ui.md`).
- **Menu native** (`StatusItemController+*.swift`): cards theo provider với reset
  countdown (mặc định) / absolute, Overview Detailed/Compact, hover highlight,
  manual-refresh spinner cố định geometry + coalescing, Share Snapshot PNG/TIFF.
- **Ổn định vị trí:** autosave identity, giữ Cmd-drag qua refresh, xóa item khi quit
  để không kẹt slot trống; chẩn đoán opt-in `CODEXBAR_STATUS_ITEM_DIAGNOSTICS=1`
  (`docs/status-item-diagnostics.md`).

## 3. Provider: chuỗi nguồn + fallback (đáng học nhất)

Kiến trúc: mỗi provider là **descriptor** đăng ký nhiều `ProviderFetchStrategy`
(`ProviderFetchPlan.swift:335`); runtime chọn strategy, fallback theo chuỗi rõ ràng.

**Claude** (`Sources/CodexBarCore/Providers/Claude/`, `docs/claude.md`):
- OAuth API trước: env override → cache Keychain → file `~/.claude/.credentials.json`
  → Keychain `Claude Code-credentials`; tự refresh `POST /v1/oauth/token`,
  `invalid_grant` chặn tới khi fingerprint đổi, 401/backoff mũ tới 6h, cooldown
  khi bị từ chối Keychain. `GET .../api/oauth/usage?cedar_ember=1`,
  beta `oauth-2025-04-20` (`ClaudeOAuthUsageFetcher.swift`,
  `ClaudeOAuthRefreshFailureGate.swift`, `ClaudeOAuthKeychain*Gate*.swift`...).
- Fallback app runtime: **OAuth → CLI PTY (`/usage` trong PTY, parse frame con trỏ)
  → Web cookies** (`ClaudeStatusProbe.swift`, `ClaudeCLISession.swift`).
- Web cookies opt-in (Safari→Chrome→Firefox, domain `claude.ai`/`sessionKey`),
  Admin API spend (`sk-ant-admin...` → cost/usage_report), multi-account
  (`tokenAccounts`, `claude-swap`), model-scoped weekly (`ClaudeScopedWeeklyLimitMapper`).
- Map window: `five_hour`→session, `seven_day`→weekly, `*_sonnet/opus` +
  `limits[].weekly_scoped`→scoped weekly, `extra_usage`→credits $.

**Codex** (`Sources/CodexBarCore/Providers/Codex/`, `docs/codex.md`, `docs/codex-oauth.md`):
- Chuỗi Auto: **PAT → OAuth (`~/.codex/auth.json`, read-only, CLI sở hữu refresh)
  → CLI RPC** (`initialize` + `account/read` + `account/rateLimits/read`,
  SIGTERM→SIGKILL, timeout giới hạn).
- OAuth trực tiếp `GET {chatgpt_base_url}/wham/usage` + JWT `exp`/8d freshness,
  stale native → CLI recovery (`CodexOAuthUsageFetcher.swift`, `CodexTokenRefresher.swift`).
- Chuẩn hóa window theo duration (`CodexRateWindowNormalizer.swift`),
  **weekly-reset publication gate**: reset weekly khả nghi bị giữ + giữ last-trusted,
  cần 2 lần đọc trùng plan + tồn kho reset-credit tương thích mới publish.
- Dashboard web opt-in (WKWebView scrape review/breakdown/credits history),
  managed accounts/workspace, `additional_rate_limits[]` → extra windows ẩn/hiện được.
- Cost scan local tách bạch quota: `~/.codex/sessions/**/*.jsonl` + WAL SQLite
  (giới hạn 25k entries/256MiB), dedup fork/subagent (`docs/codex.md`).

**Cursor** (app này đã có, đối chiếu): CodexBar đọc cookie/localStorage hoặc SQLite
local; app này đọc read-only `state.vscdb` + JWT check — cùng triết lý, giữ nguyên.

## 4. Refresh loop

- `RefreshFrequency`: Manual, 1m, 2m, 5m, 15m, 30m, **Adaptive** (mặc định cài mới),
  **Adaptive (agent-aware)**. Cài cũ giữ lựa chọn, unset/invalid → 5 phút
  (`docs/refresh-loop.md`).
- `AdaptiveRefreshPolicyCore.nextDelay(Input)`: LowPower/thermal→30m; menu ≤5m→2m;
  menu 5m–1h→5m; coding activity→5m; menu 1–4h→15m; còn lại→30m. Bounds 2–30m;
  cố ý **không** dùng ML/dự đoán (`docs/predictive-refresh-policy.md`; replay
  1.780-record: agent-aware giảm ~49,7% refresh vs 5m cố định, p95 staleness tương đương).
- Agent-aware riêng, consent `undecided/allowed/declined`, scan mtime
  `rollout-*.jsonl` + process 30s, chỉ giữ `Date` mới nhất khi UI session tắt
  (`docs/refresh-loop.md`, `LocalAgentSessionScanner` ở Core).
- Stale: lỗi transport → **giữ snapshot + `updatedAt` gốc**; auth failure/account
  đổi → invalidate. Không retry ngay sau batch lỗi; `Refresh now` luôn có trong menu.
- Menu-open refresh: mặc định chỉ provider thiếu/lỗi; opt-in refresh all; không reset
  đồng hồ định kỳ. 429 → status `rateLimited`, **không backoff riêng**, serve
  last-good tới 10 intervals (tối thiểu 5m) + stale-while-revalidate (`docs/cli.md#serve`).

## 5. Status page, history/burndown, cost trung thực

- `ProviderStatusFetcher` (Core): Statuspage.io `api/v2/status.json` (OpenAI, Claude,
  Cursor...) + Google `incidents.json` (Gemini...). Toggle
  Settings → Advanced; menu hiện incident + freshness; icon overlay
  (`docs/status.md`).
- **Burndown quota** (Codex/Claude Plan Usage): burndown từ snapshot đã ghi nằm trên
  utilization history + even-use guide; retention/ngữ nghĩa ở `docs/widgets/burndown-proof.md`;
  code ở `BurnDownWidgetProvider.swift`.
- **Cost honesty** (`docs/cost-reporting-periods.md`, `docs/cost-window-comparisons.md`):
  rolling-days + month-to-date + all; summary = `recorded spend`, không phải bill;
  priced+unpriced lẫn → totals unavailable; missing ≠ zero; không bịa model/giá.
  App này hiện chỉ có Claude Usage credits — nên giữ cùng kỷ luật khi mở rộng.

## 6. Widget, CLI, notification, config

- **Widget** (`Sources/CodexBarWidget/`, `docs/widgets.md`): app → `WidgetSnapshotStore`
  JSON gọn → app-group → timeline. 8 loại: Switcher, Usage (2× cho Claude+Codex
  cạnh nhau), Account Usage, Accounts, History, Metric/Cost, Burn Down,
  Burn Down Combined. macOS 15 dùng live date text; 14 fallback relative-date.
- **CLI** (`Sources/CodexBarCLI/`): `usage [--format text|json|toon]
  [--provider|--source|--account|--status|--breakdown]`, `cost`, `cards`,
  `dashboard`, `serve` (`GET /,/health,/usage,/cost,/dashboard/v1/snapshot`,
  token cho non-loopback), `cache clear`, `cookie refresh`, **`guard --provider
  --min-remaining --window`** (exit 0/1/64/69 — hợp cho scripting/CI),
  `config validate/dump/enable/disable/set-api-key --stdin`,
  `hooks list|enable|disable|test|watch`, `sessions`, `codex-accounts`.
- **Notification** (`AppNotifications.swift`, `SessionQuotaNotifications.swift`,
  `docs/credential-notifications.md` + `docs/ui.md`): reset notification **mặc định off**,
  dedupe per provider/account/window, tôn trọng Focus/DND, không cần quyền thêm;
  credential-expiry alert off-by-default, 1 alert/episode, payload chỉ tên provider;
  **weekly-reset confetti**.
- **Config** (`docs/configuration.md`): JSON dùng chung app+CLI
  (`~/.config/codexbar/config.json`, legacy `~/.codexbar/`), file `0600`,
  atomic replace + lock; secrets tách: config (apiKey/cookie) vs Keychain (cache/OAuth)
  vs CloudKit opt-in; `UserDefaults` giữ runtime prefs; `preferences export/import`
  allowlist rõ ràng.

## 7. Gợi ý bổ sung cho app này (xếp theo effort/tác động)

App này đã có (xác nhận từ code hiện tại): 9-provider enum + `supported`,
`UsageProvider` adapters độc lập, `UsageStore` refresh/stale/status,
`RefreshPolicy` (1/5/10/15m + Manual), `MenuBarDisplayMode`
(iconOnly/combinedUsage/providerSpecific/criticalProviderOnly),
`MenuBarStatusView`, Cursor read-only SQLite, launch-at-login. Dưới đây là phần
CodexBar có mà app này còn thiếu, xếp từ dễ → khó:

**P0 — cứng cáp provider hiện tại (port trực tiếp):**
1. `Retry-After` date-format + cap 30s cho 429 Claude (đã có một phần ở
   `ClaudeRetryPolicy` — đối chiếu thêm UTC parse của họ).
2. Keychain read policy: cooldown sau denial, non-interactive probe trước
   (`ClaudeOAuthKeychain*Gate*.swift`) — tránh spam prompt macOS.
3. Phân biệt transport-error (giữ snapshot) vs auth-error (invalidate) +
   status `rateLimited` riêng — app này đã có `ProviderStatus`, chỉ cần siết classifier.
4. Weekly-reset publication gate cho Codex (giữ last-trusted khi reset khả nghi)
   thay vì tin timestamp server ngay.
5. Fixture response đã ẩn nhạy cảm + parser tests cho payload mới (họ có sharded suite).

**P1 — menu bar & visibility (vốn liếng lớn nhất của CodexBar):**
6. Dim icon khi stale + incident/status dot — mở rộng `MenuBarStatusView` hiện có.
7. Reset countdown trong popover + token đơn giản `{icon} {C %} · {A %} | resets-in`,
   thiếu dữ liệu → `—` (bản rút gọn của `MenuBarLayout`, chưa cần editor kéo-thả).
8. Reset notification off-by-default + dedupe per provider/window (`SessionQuotaNotifications.swift`).
9. Adaptive refresh rút gọn: menu-recency (2m/5m/15m/30m) + Low Power/thermal,
   pure function dễ test như `AdaptiveRefreshPolicyCore` — không cần agent-aware.
10. Status page poll (Statuspage.io) cho Claude/OpenAI — file fetch nhỏ, UI overlay có sẵn ý tưởng.

**P2 — data & platform (khi snapshot/cache ổn định):**
11. Lịch sử snapshot giới hạn retention + burndown đơn giản (SQLite hoặc JSONL),
    trước khi làm chart.
12. 1–2 WidgetKit Usage (Claude+Codex) qua app-group JSON như `WidgetSnapshotStore`.
13. CLI tối thiểu: `usage --json`, `guard --min-remaining` (exit codes cho scripting).
14. Cost scan local tách bạch quota + kỷ luật honesty (recorded ≠ bill).
15. i18n catalog, Sparkle updater, notarization (họ có `Scripts/sign-and-notarize.sh`,
    `make_appcast.sh`).

**Không nên port:** full token editor + V2/V3/V4 projections, pace engine + work-days
model, 23-locale sync, CloudKit fleet sync, multi-account switcher 6+, frontmost-app
tracking, ~100 provider descriptors — vượt scope app nhỏ.

## 8. Tra cứu tiếp bằng codegraph

Index ở `research/.codegraph/codegraph.db` (config `research/codegraph.json`
giữ `CodexBar/` khỏi ignore). Lệnh mẫu:

```bash
codegraph explore -p research "menu bar status item icon rendering NSStatusItem"
codegraph explore -p research "Claude OAuth usage fetch provider token refresh"
codegraph explore -p research "Codex app-server rate limits provider OAuth wham usage"
codegraph explore -p research "adaptive refresh policy timer cadence"
codegraph explore -p research "WidgetKit timeline snapshot provider"
codegraph explore -p research "CLI usage cost serve guard command"
codegraph node -p research -f CodexBar/Sources/AdaptiveRefreshCore/AdaptiveRefreshPolicyCore.swift --symbols-only
codegraph query -p research "ProviderFetchStrategy" -l 10
```
