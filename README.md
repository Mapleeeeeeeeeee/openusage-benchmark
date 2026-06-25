# OpenUsage Harness Benchmark

測量 Claude Code 不同 harness 設定對 token 消耗和功能正確性的影響。

## 研究問題

> 給 Claude 相同的任務，不同的 harness 設定（CLAUDE.md、subagents、skills）會讓 token 消耗差多少？功能品質有沒有差？

## 5 個場景

| 場景 | CLAUDE.md | AGENTS.md | 子代理 (Task) | 技能文件 (Skills) |
|------|-----------|-----------|---------------|-------------------|
| S1 裸機 | ✗ | ✗ | ✗ | ✗ |
| S2 CLAUDE.md | ✓ | ✓ | ✗ | ✗ |
| S3 子代理 | ✓ | ✓ | ✓ | ✗ |
| S4 技能文件 | ✓ | ✓ | ✗ | ✓ (Tauri skills) |
| S5 全開 | ✓ | ✓ | ✓ | ✓ |

每個場景在獨立的 Docker 容器中執行 `claude -p`，無全域 CLAUDE.md、無 hooks、`alwaysThinkingEnabled=false`。

## 任務

在 [openusage](https://github.com/robinebers/openusage) 的 Codex plugin 中加入 rate limit reset 狀態功能（基於 [PR #287](https://github.com/robinebers/openusage/pull/287)）。Claude 必須通過既有的 plugin 測試和獨立的行為測試才算完成。

## 驗證方法論

三層驗證確保結果可信：

1. **靜態檢查** — grep 驗證 API URL、community link、快取機制、錯誤處理
2. **Claude 的測試** — Claude 自己寫的 vitest（`plugins/codex/`）
3. **行為測試** — `behavioral.test.js`，獨立於 Claude 的實作，基於 PR #287 的行為 contract：
   - reset=yes → 綠色正面指標
   - reset=no → 紅色負面指標
   - API 錯誤 → 不顯示、不 crash
4. **跨場景一致性** — 所有場景使用相同 API 端點和 line type

## 快速開始

### 前置條件

- Docker
- Claude Code CLI 帳號（用於 Docker 內 OAuth）

### 1. Docker 登入（首次）

```bash
./docker-login.sh
# 容器內執行 claude，瀏覽器完成 OAuth，exit 離開
```

### 2. 正式 benchmark

```bash
# 完整 5 場景（Sonnet，約 10-20 分鐘）
./run_in_docker.sh --skip-init

# 用 Haiku 快速驗證 pipeline
./run_in_docker.sh --e2e --skip-init
```

### 3. 看結果

```bash
# JSON 原始資料
cat results/run_*.json | jq

# HTML 報告（含圖表）
open results/benchmark_report.html

# 驗證報告
cat results/validate_*.txt
```

## 開發與測試

```bash
# Unit test（不需要 Docker 或 Claude）
bash test_benchmark.sh

# Dry-run（mock claude -p，測試 pipeline 骨架）
./run_benchmark.sh --dry-run

# 用現有 tmp-runs 單獨跑驗證
./validate.sh tmp-runs/openusage-bm-<timestamp> results/run_<timestamp>.json
```

## 檔案結構

```
run_benchmark.sh      主流程（Phase 0-4）
validate.sh           驗證腳本（靜態檢查 + 測試 + 行為測試 + 一致性）
behavioral.test.js    獨立行為測試（基於 PR #287 contract）
test_benchmark.sh     Unit test（hook jq、token 解析、場景設定）
hook_settings.json    SubagentStart / PostToolUse(Skill) 監控 hook
cached_claude_md.md   快取的 CLAUDE.md（--skip-init 使用）

run_in_docker.sh      Docker 執行入口
docker-login.sh       Docker 內 Claude OAuth 登入
entrypoint.sh         容器環境消毒
Dockerfile            node + bun + jq + claude-code

results/              所有 run JSON + validate 報告 + HTML 報告
```

## 執行參數

| Flag | 說明 |
|------|------|
| `--skip-init` | 跳過 `/init` 生成 CLAUDE.md，使用 `cached_claude_md.md` |
| `--e2e` | 使用 Haiku 模型（便宜，驗證 pipeline） |
| `--dry-run` | Mock `claude -p`，秒級跑完，測試 pipeline 不花 AI 費用 |

## 模型與設定

- **模型**：claude-sonnet-4-6（正式）/ claude-haiku-4-5（e2e 驗證）
- **Effort**：low
- **輸出格式**：text

## 結論摘要（3 次 Sonnet 平均）

| 場景 | 加權 token | vs S1 |
|------|-----------|-------|
| S1 裸機 | 3.75M | — |
| S2 CLAUDE.md | 2.52M | -33% |
| S3 子代理 | 2.65M | -29% |
| S4 技能文件 | 1.93M | -49% |
| S5 全開 | 1.88M | **-50%** |

詳細數據和圖表見 `results/benchmark_report.html`。
