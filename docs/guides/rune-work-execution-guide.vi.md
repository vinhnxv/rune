# Hướng dẫn Rune (Tiếng Việt): `/rune:strive` và `/rune:goldmask`

Hướng dẫn này bao gồm các workflow thực thi và phân tích tác động của Rune:
- `/rune:strive` — thực thi plan với worker tự tổ chức theo mô hình swarm.
- `/rune:goldmask` — phân tích tác động đa tầng trước hoặc sau thay đổi.

Các hướng dẫn liên quan:
- [Hướng dẫn arc và batch (arc/arc-batch)](rune-arc-and-batch-guide.vi.md)
- [Hướng dẫn planning (devise/forge/plan-review/inspect)](rune-planning-and-plan-quality-guide.vi.md)
- [Hướng dẫn review và audit (appraise/audit/mend)](rune-code-review-and-audit-guide.vi.md)

## Đọc nhanh (2 phút)

- Muốn triển khai plan: dùng `/rune:strive`.
- Muốn đo rủi ro trước khi sửa: dùng `/rune:goldmask`.
- Muốn pipeline đầy đủ từ plan tới PR/merge: dùng `/rune:arc`.
- Nếu bạn mới dùng, chạy theo thứ tự: `plan -> work -> review`.
- Thuật ngữ tham khảo: [Thuật ngữ Rune (Tiếng Việt)](rune-glossary.vi.md).

---

## 1. Chọn lệnh nhanh

| Tình huống | Lệnh khuyến nghị |
|---|---|
| Thực thi plan với worker swarm | `/rune:strive plans/my-plan.md` |
| Thực thi với phê duyệt từng task | `/rune:strive plans/my-plan.md --approve` |
| Phân tích blast radius của thay đổi hiện tại | `/rune:goldmask` |
| Kiểm tra rủi ro nhanh (không agent) | `/rune:goldmask --quick` |
| Xếp hạng rủi ro file trước khi sửa | `/rune:goldmask --lore src/auth/` |
| Pipeline đầy đủ (plan đến merged PR) | `/rune:arc plans/my-plan.md` (dùng strive bên trong) |

---

## 2. Yêu cầu

### Bắt buộc
- Claude Code đã cài plugin Rune.
- Agent Teams đã bật (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`).
- File plan cho strive (trong thư mục `plans/`).

### Khuyến nghị
- Git branch sạch (strive cảnh báo nếu trên `main` và đề nghị tạo feature branch).
- `gh` CLI đã cài để tự động tạo PR (strive Phase 6.5).
- Đủ token budget cho multi-agent work.

### Tùy chọn
- `codex` CLI cho cross-model verification sau implementation.
- `.rune/talisman.yml` để tinh chỉnh số worker, ward command, và commit format.

---

## 3. `/rune:strive` — Thực thi Swarm

### 3.1 Sử dụng cơ bản

```bash
/rune:strive plans/my-plan.md
```

Rune phân tích plan thành task, khởi tạo worker tự tổ chức, và thực thi plan với quality gate.

### 3.2 Các flag

| Flag | Tác dụng |
|---|---|
| `--approve` | Yêu cầu phê duyệt trước khi mỗi task bắt đầu code |
| `--worktree` | Sử dụng git worktree isolation — mỗi worker có bản sao repo riêng (v1.122.0+) |

### 3.3 Quy trình strive

1. **Phân tích plan** — trích xuất task với dependency, làm rõ mơ hồ.
2. **Thiết lập môi trường** — kiểm tra branch (cảnh báo trên `main`), stash file dirty.
3. **Tạo task pool** — `TaskCreate` với chuỗi dependency (`blockedBy`).
4. **Khởi tạo worker** — Rune Smith (implementation) và Trial Forger (test) nhận task độc lập.
5. **Giám sát** — poll TaskList mỗi 30s, phát hiện worker bị kẹt (cảnh báo 5 phút, tự giải phóng 10 phút).
6. **Commit broker** — orchestrator apply patch và commit (tránh index.lock contention).
7. **Ward check** — chạy quality gate + checklist xác minh.
8. **Doc-consistency** — phát hiện drift version/count (non-blocking).
9. **Lưu echo** — lưu pattern implementation vào `.rune/echoes/workers/`.
10. **Dọn dẹp** — shutdown worker, TeamDelete, restore file đã stash.
11. **Ship (tùy chọn)** — push + tạo PR với template.

### 3.4 Loại worker

| Worker | Vai trò | Khi nào dùng |
|---|---|---|
| **Rune Smith** | Implementation code (TDD-aware) | Task implementation |
| **Trial Forger** | Tạo test theo pattern dự án | Task test |

Worker tự tổ chức: poll task list, nhận task chưa bị block, và làm việc độc lập. Orchestrator (Tarnished) điều phối nhưng không bao giờ implement code trực tiếp.

### 3.5 Commit broker

Worker không commit trực tiếp. Thay vào đó:
1. Worker tạo patch file sau khi hoàn thành task.
2. Orchestrator đọc patch và apply với `git apply --3way` fallback.
3. Một commit mỗi task: `rune: <task-subject> [ward-checked]`.

Điều này tránh git index.lock contention khi nhiều worker hoàn thành cùng lúc.

### 3.6 Worktree isolation (v1.122.0+)

```bash
/rune:strive plans/my-plan.md --worktree
```

Với `--worktree`, mỗi worker có git worktree riêng — bản sao cách ly của repository. Lợi ích:
- **Không xung đột index.lock** — worker commit độc lập.
- **Không merge conflict khi làm việc** — mỗi worktree độc lập.
- **Tự động dọn dẹp** — worktree mồ côi được garbage-collect bởi 3 safety net:
  1. `on-session-stop.sh` tự dọn khi session kết thúc (giới hạn 3).
  2. `session-team-hygiene.sh` phát hiện orphan khi bắt đầu session.
  3. `/rune:rest` bao gồm dọn worktree thủ công.

Kiểm tra PID liveness đảm bảo worktree từ session đang sống không bao giờ bị dọn.

Cấu hình qua talisman:

```yaml
work:
  worktree:
    enabled: true        # Bật worktree isolation mặc định
```

### 3.7 Worker safety caps (v1.119.0+)

Worker có giới hạn an toàn tích hợp để ngăn vòng lặp vô hạn:
- **maxTurns: 60** — giới hạn cứng cho agentic turns (giảm từ 120 trong v1.119.0).
- **Runtime budget enforcement** — tín hiệu `force_shutdown` kích hoạt emergency worker shutdown.
- **TeammateIdle bypass** — work team bỏ qua idle quality gate để ngăn false stall.

### 3.8 Tự động scale worker

| Số task | Worker |
|---|---|
| 1-5 task | 2 worker |
| 6-10 task | 3 worker |
| 11-19 task | 4 worker |
| 20+ task | 5 worker |

Cấu hình max worker qua `talisman.yml`:

```yaml
work:
  max_workers: 3
```

### 3.9 Chế độ phê duyệt

```bash
/rune:strive plans/my-plan.md --approve
```

Với `--approve`, orchestrator trình bày mỗi task qua `AskUserQuestion` trước khi worker bắt đầu code. Cho bạn kiểm soát ở cấp task cho implementation rủi ro cao.

### 3.10 Phase Ship

Sau khi tất cả task hoàn thành và ward pass, strive tùy chọn:
1. Push branch lên remote.
2. Tạo PR qua `gh pr create` với template.

Phase này là opt-in. Không có `gh` CLI hoặc branch không an toàn thì bị bỏ qua.

---

## 4. `/rune:goldmask` — Phân tích tác động

### 4.1 Sử dụng cơ bản

```bash
/rune:goldmask
```

Phân tích diff hiện tại qua ba tầng: gì thay đổi (Impact), tại sao được viết như vậy (Wisdom), và khu vực rủi ro thế nào (Lore).

### 4.2 Các chế độ

| Chế độ | Lệnh | Agent | Use case |
|---|---|---|---|
| **Điều tra đầy đủ** | `/rune:goldmask` | 8 agent | Phân tích toàn diện trước refactor rủi ro |
| **Kiểm tra nhanh** | `/rune:goldmask --quick` | 0 (deterministic) | Xác minh nhanh sau implementation |
| **Intelligence** | `/rune:goldmask --lore <files>` | 1 agent | Xếp hạng rủi ro file trước khi sửa thủ công |

### 4.3 Các flag

| Flag | Tác dụng |
|---|---|
| *(không flag)* | Điều tra 3 tầng đầy đủ trên diff hiện tại |
| `--quick` | Chỉ kiểm tra deterministic (so sánh dự đoán vs thực tế) |
| `--lore <files>` | Chỉ phân tích Lore (output: danh sách file xếp theo rủi ro) |
| `<diff-spec>` | Git range (`HEAD~3..HEAD`) hoặc đường dẫn file |

### 4.4 Ba tầng phân tích

**Impact Layer** (5 tracer, Haiku):
Truy vết gì cần thay đổi qua dependency graph.
- Data layer tracer — schema, ORM, serializer, migration
- API contract tracer — route, handler, validator, docs
- Business logic tracer — service, domain rule, state machine
- Event/message tracer — publisher, subscriber, dead letter queue
- Config/dependency tracer — env var, config file, CI pipeline

**Wisdom Layer** (1 sage, Sonnet):
Điều tra tại sao code được viết như vậy.
- Phân tích git blame, phân loại intent từ commit message
- Điểm caution cho modification an toàn

**Lore Layer** (1 analyst, Haiku):
Lượng hóa mức rủi ro khu vực.
- Churn metric từ git, co-change clustering
- Ownership concentration, hotspot detection
- Output `risk-map.json` cho forge, mend, inspect dùng

### 4.5 File output

```
tmp/goldmask/{session_id}/
├── GOLDMASK.md          # Báo cáo tổng hợp
├── findings.json        # Phát hiện dạng machine-readable
├── risk-map.json        # Điểm rủi ro per-file
├── wisdom-report.md     # Phân tích Wisdom Layer
├── data-layer.md        # Output từ Impact tracer
├── api-contract.md
├── business-logic.md
├── event-message.md
└── config-dependency.md
```

### 4.6 Tích hợp với workflow khác

Dữ liệu Goldmask được tự động sử dụng bởi:
- **Forge** — ưu tiên section theo rủi ro (Phase 1.5)
- **Mend** — severity overlay theo rủi ro, inject risk context cho fixer
- **Inspect** — ưu tiên gap theo rủi ro (Phase 1.3)
- **Devise** — Goldmask dự đoán cho đánh giá rủi ro trước implementation
- **Arc** — Goldmask Verification (Phase 5.7) + Goldmask Correlation (Phase 6.5)

---

## 5. Kết hợp Strive và Goldmask

### Đánh giá rủi ro trước implementation

```bash
/rune:goldmask                        # Hiểu blast radius
/rune:strive plans/my-plan.md         # Implement với nhận thức rủi ro
```

### Xác minh sau implementation

```bash
/rune:strive plans/my-plan.md
/rune:goldmask --quick                # Kiểm tra dự đoán vs thay đổi thực tế
```

### Pipeline đầy đủ (khuyến nghị)

```bash
/rune:arc plans/my-plan.md
```

Arc chạy goldmask và strive bên trong với checkpoint-based resume.

---

## 6. Use Case

### 6.1 Implementation feature từ plan

```bash
/rune:strive plans/2026-02-24-feat-user-auth-plan.md
```

Thực thi swarm tiêu chuẩn. Worker phân tích plan, nhận task, và implement độc lập.

### 6.2 Refactor rủi ro cao với phân tích trước

```bash
/rune:goldmask
# Kiểm tra GOLDMASK.md cho blast radius
/rune:strive plans/refactor-auth-plan.md --approve
```

Chạy goldmask trước để hiểu rủi ro. Dùng `--approve` cho oversight ở cấp task.

### 6.3 Kiểm tra rủi ro nhanh trước khi sửa thủ công

```bash
/rune:goldmask --lore src/auth/ src/middleware/
```

Xếp hạng rủi ro file theo git history trước khi bạn bắt đầu sửa thủ công.

### 6.4 Implementation với kiểm soát nghiêm ngặt

```bash
/rune:strive plans/my-plan.md --approve
```

Phê duyệt từng task. Tốt cho critical path hoặc khi mới làm quen codebase.

---

## 7. Cấu hình

```yaml
# .rune/talisman.yml
work:
  max_workers: 3                    # Max worker song song (mặc định: tự scale)
  ward_commands:                    # Override quality gate command
    - "make check"
    - "npm test"
  approve_timeout: 180              # Giây (mặc định: 3 phút)
  commit_format: "rune: {subject} [ward-checked]"
  skip_branch_check: false          # Bỏ qua kiểm tra branch
  branch_prefix: "rune/work"       # Prefix feature branch
  co_authors: []                    # Co-Authored-By line

goldmask:
  enabled: true
  devise:
    enabled: true
    depth: basic                    # basic | enhanced | full
```

---

## 8. Xử lý sự cố

| Triệu chứng | Nguyên nhân | Hành động |
|---|---|---|
| Worker không nhận task | Task bị block bởi dependency | Kiểm tra task pool cho chuỗi `blockedBy` |
| Worker bị kẹt (>5 phút) | Task phức tạp hoặc worker stuck | Tự giải phóng sau 10 phút. Lead re-assign |
| Ward check thất bại | Bug implementation hoặc test fail | Sửa và chạy lại ward thủ công |
| Commit conflict | Hai worker sửa cùng file | File ownership qua `blockedBy` nên ngăn điều này. Báo nếu gặp |
| Goldmask timeout | Diff lớn hoặc nhiều file | Dùng `--lore` cho phân tích nhẹ hơn |
| "No plan file" | Path sai hoặc plan thiếu | Kiểm tra plan tồn tại trong `plans/` |
| Phase Ship bị bỏ qua | `gh` CLI thiếu hoặc branch không an toàn | Cài `gh` và authenticate |
| Worktree cleanup bị kẹt | Thư mục rune-work-* mồ côi | `/rune:rest` hoặc khởi động lại session cho auto-GC |
| Worker lặp vô hạn | maxTurns vượt quá | v1.119.0+ giới hạn 60 turns với force_shutdown |
| Worker treo sau task | Idle bypass không hoạt động | Kiểm tra TeammateIdle hook bypass cho work team |

---

## 9. Tham chiếu lệnh nhanh

```bash
# Thực thi swarm
/rune:strive plans/my-plan.md                      # Thực thi tiêu chuẩn
/rune:strive plans/my-plan.md --approve            # Phê duyệt từng task
/rune:strive plans/my-plan.md --worktree           # Worktree isolation

# Phân tích tác động
/rune:goldmask                                     # Điều tra 3 tầng đầy đủ
/rune:goldmask --quick                             # Kiểm tra deterministic
/rune:goldmask --lore src/auth/                    # Xếp hạng rủi ro file

# Pipeline đầy đủ (bao gồm cả hai)
/rune:arc plans/my-plan.md
```
