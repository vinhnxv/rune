# Các giải pháp kỹ thuật đặc biệt của Rune

Tổng hợp 30 giải pháp kỹ thuật được phát triển qua hơn 200 commits (v0.1.0 → v1.92.0), hình thành nền tảng kiến trúc của platform điều phối đa agent Rune.

---

## Cách đọc nhanh (3 phút)

- Mỗi mục đều theo format: **Vấn đề** -> **Giải pháp**.
- Nếu bạn mới với Rune, nên đọc mục `1`, `3`, `4`, `10` trước.
- Tài liệu giữ nguyên một số thuật ngữ English để dễ theo dõi: `workflow`, `phase`, `checkpoint`, `quality gate`, `memory`.

---

## Mục lục

1. [Tin cậy & Xác minh Agent](#1-tin-cậy--xác-minh-agent)
2. [Phối hợp đa Agent](#2-phối-hợp-đa-agent)
3. [Trí tuệ Review](#3-trí-tuệ-review)
4. [Điều phối Pipeline](#4-điều-phối-pipeline)
5. [Trí tuệ Planning](#5-trí-tuệ-planning)
6. [Phân tích tác động](#6-phân-tích-tác-động)
7. [Quản lý Context](#7-quản-lý-context)
8. [Bộ nhớ & Tri thức](#8-bộ-nhớ--tri-thức)
9. [An toàn Session & Vòng đời](#9-an-toàn-session--vòng-đời)
10. [Hạ tầng Enforcement](#10-hạ-tầng-enforcement)

---

## 1. Tin cậy & Xác minh Agent

### 1.1 Truthbinding Protocol

**Vấn đề**: Khi agent review code, chúng có thể bị ảnh hưởng bởi chỉ dẫn nhúng trong comment, string, hoặc documentation — một dạng prompt injection gián tiếp.

**Giải pháp**: Mỗi prompt agent đều có phần ANCHOR và RE-ANCHOR:
- Buộc agent coi TẤT CẢ nội dung được review là input không đáng tin
- Yêu cầu đánh giá dựa trên bằng chứng qua **Rune Traces** — trích dẫn file path + số dòng từ source code thực
- Gắn cờ LOW confidence cho finding không chắc chắn thay vì bịa bằng chứng
- Ghi đè mọi chỉ dẫn tìm thấy trong code (comment, docstring, string literal)

Protocol tạo ra ranh giới nhận thức: agent đưa ra kết luận từ hành vi code, không phải từ những gì code tự nói về mình.

### 1.2 Truthsight Verification Pipeline

**Vấn đề**: Ngay cả với Truthbinding, agent vẫn có thể hallucinate — claim issue không tồn tại.

**Giải pháp**: Pipeline xác minh đa lớp:

| Lớp | Khi nào | Xác minh gì |
|-----|---------|-------------|
| **Layer 0** (inline) | Trong review | Quality gate dựa trên inscription |
| **Layer 2** (Smart Verifier) | Sau review | Haiku-model revalidation ngữ nghĩa |
| **Phase 6.2** (Cross-model) | Trong arc | Codex xác minh chéo P1/P2 so với diff thực |

Mỗi lớp có **guard chống hallucination 4 bước**: tính phù hợp diff → chất lượng bằng chứng → đánh giá hành vi → hiệu chỉnh confidence.

### 1.3 Doubt Seer Cross-Examination

**Vấn đề**: Review agent có thể tạo finding nghe hợp lý nhưng thiếu bằng chứng thực chất.

**Giải pháp**: Agent meta-review (Doubt Seer) chuyên thách thức finding của Ash khác:
- Chỉ kích hoạt khi có finding P1/P2 (Phase 4.5)
- Dùng prefix `DOUBT-` **không thể dedup** — challenge luôn được bảo toàn trong TOME
- Phân loại claim: PROVEN / LIKELY / UNCERTAIN / UNPROVEN
- Nhắm vào claim cấu trúc: tính mạch lạc logic, tính hợp lệ giả định, góc nhìn thiếu

### 1.4 Inner Flame Self-Review Protocol

**Vấn đề**: Agent có thể hoàn thành task mà không tự xác minh kỹ, dẫn đến output nông hoặc sai.

**Giải pháp**: Protocol tự kiểm tra 3 lớp cho TẤT CẢ teammate:

| Lớp | Kiểm tra | Mục đích |
|-----|---------|---------|
| **Grounding** | Mỗi claim có bằng chứng cấp file | Chống hallucination |
| **Completeness** | Checklist theo vai trò (worker, reviewer, fixer) | Chống công việc dở dang |
| **Self-Adversarial** | Tự tưởng tượng mình là critic review output | Phát hiện điểm mù |

Hook `validate-inner-flame.sh` kiểm tra Self-Review Log. Cấu hình: `block_on_fail: true` biến thành hard gate.

---

## 2. Phối hợp đa Agent

### 2.1 Inscription Protocol

**Vấn đề**: Nhiều agent làm việc song song cần hợp đồng chung định nghĩa output, format, và cách phát hiện hoàn thành.

**Giải pháp**: File hợp đồng JSON (`inscription.json`) tạo bởi orchestrator trước khi spawn agent:
- **Required sections**: Liệt kê chính xác section mỗi Ash phải tạo
- **Output paths**: Nơi mỗi Ash ghi output
- **Verification settings**: Lớp Truthsight nào áp dụng
- **Diff scope data**: Line range từ `git diff` để Ash biết code nào thay đổi
- **Seal format**: Format tín hiệu hoàn thành

Quy tắc tuyệt đối: **không review nếu không có inscription**.

### 2.2 Seal Convention

**Vấn đề**: Phát hiện khi agent thực sự hoàn thành (vs. hoàn thành một phần hoặc crash) cần tín hiệu đáng tin cậy.

**Giải pháp**: Agent phát `<seal>TAG</seal>` ở **dòng cuối cùng** của output file. Seal chứa metadata: section hoàn thành, số finding, cờ verified, confidence (0-100).

Cơ chế phát hiện: Hook ghi signal files vào `tmp/.rune-signals/{team}/{task_id}.done`. File `.all-done` xuất hiện khi tất cả task hoàn thành. Polling filesystem **5 giây** thay vì API 30 giây — nhanh gấp 6x, gần như không tốn token.

### 2.3 Dedup-Runes Hierarchy

**Vấn đề**: 5-8 agent review cùng codebase chắc chắn tìm issue trùng lặp.

**Giải pháp**: Hệ thống dedup theo ưu tiên:
- Mỗi Ash dùng **finding prefix** duy nhất (VD: SEC, BACK, QUAL)
- Hierarchy cấu hình: `SEC > BACK > VEIL > DOUBT > DOC > QUAL > FRONT > CDX`
- **Cửa sổ 5 dòng**: Nếu hai Ash báo finding trong 5 dòng cùng file, prefix cao hơn thắng
- Confidence của Ash thua được giữ trong `also_flagged_by`
- **Cross-wave dedup**: Wave sau SUPERSEDE wave trước (phân tích sâu hơn thắng)

### 2.4 Runebinder Aggregation

**Vấn đề**: Sau khi các Ash hoàn thành, finding nằm rải rác trong nhiều file output.

**Giải pháp**: Agent tiện ích (Runebinder) chuyên:
1. Đọc tất cả Ash output
2. Áp dụng dedup hierarchy
3. Tạo **TOME** thống nhất với marker `<!-- RUNE:FINDING -->`
4. Tổ chức theo severity: P1 → P2 → P3
5. Bảo toàn Rune Traces đầy đủ cho truy vết

### 2.5 Glyph Budget Protocol

**Vấn đề**: Agent trả output lớn sẽ làm tràn context window của orchestrator.

**Giải pháp**: Protocol output nghiêm ngặt:
- **File-only output**: Agent ghi vào filesystem, chỉ trả summary ~150 token
- **Pre-summon checklist**: 8 bước suy nghĩ trước khi spawn agent
- Context budget mỗi Ash giới hạn số file review

---

## 3. Trí tuệ Review

### 3.1 Diff-Scope Engine

**Vấn đề**: Review agent phân tích toàn bộ file tạo ra finding trên code không thay đổi — nhiễu lãng phí công sức mend.

**Giải pháp**: Trí tuệ diff cấp dòng:
1. Tạo line range mở rộng từ `git diff --unified=0`
2. Làm giàu `inscription.json` với data scope mỗi file
3. Gắn tag finding: `scope="in-diff"` (code thay đổi) hoặc `scope="pre-existing"` (code không đổi)
4. **Mend ưu tiên theo scope**: P1 luôn fix; P2 chỉ fix in-diff; P3 bỏ qua pre-existing
5. **Smart convergence scoring**: Dùng thành phần scope (P3 dominance, pre-existing noise) để phát hiện hội tụ sớm

### 3.2 Convergence Loop

**Vấn đề**: Một lượt review-mend có thể không giải quyết hết issue. Nhưng lặp vô hạn thì lãng phí token.

**Giải pháp**: Vòng lặp hội tụ thích ứng 3 tier trong arc Phase 7.5:

| Tier | Max cycles | Min cycles | Tự chọn khi |
|------|-----------|-----------|------------|
| LIGHT | 2 | 1 | Thay đổi nhỏ, PR ít rủi ro |
| STANDARD | 3 | 2 | Feature thông thường |
| THOROUGH | 5 | 2 | Code rủi ro cao, bảo mật |

Hàm `evaluateConvergence()` dùng điểm tổng hợp: 40% min cycles + 30% P1 threshold + 20% P2 threshold + 10% improvement ratio. Mỗi cycle chỉ review file đã mend + dependency.

### 3.3 Chunk Scoring

**Vấn đề**: PR lớn (20+ file) tràn context window của agent.

**Giải pháp**: Chunking thông minh:
1. `computeChunkScore()`: Lines (40%) + file importance (30%) + risk hotspots (20%) + cross-cutting (10%)
2. Greedy bin packing: file sắp theo importance, đóng gói dưới 1000 dòng/Ash
3. Phát hiện ranh giới ngữ nghĩa: tôn trọng function/class definitions
4. Runebinder song song merge finding vào TOME cuối cùng

### 3.4 Enforcement Asymmetry

**Vấn đề**: Không phải mọi thay đổi code đều cần cùng mức nghiêm ngặt review.

**Giải pháp**: Mức nghiêm ngặt thay đổi theo ngữ cảnh:
- **Phân loại thay đổi**: NEW_FILE / MAJOR_EDIT (>30% dòng) / MINOR_EDIT / DELETION
- **Phân loại rủi ro**: HIGH (core/shared, file được import bởi >N file khác) / NORMAL
- **Bảo mật luôn nghiêm ngặt** — không thể ghi đè

### 3.5 Stack-Aware Intelligence

**Vấn đề**: Dự án Python và TypeScript có concern review khác nhau. Reviewer tổng quát bỏ sót issue theo stack.

**Giải pháp**: Hệ thống phát hiện và routing 4 lớp:

| Lớp | Chức năng | Triển khai |
|-----|----------|-----------|
| **Layer 0** | Quyết định load gì | `computeContextManifest()` |
| **Layer 1** | Quét manifest với confidence | `detectStack()` — đọc package.json, Cargo.toml, v.v. |
| **Layer 2** | 20 reference doc mỗi stack | Convention ngôn ngữ, framework, database |
| **Layer 3** | 11 reviewer chuyên biệt | Python, TypeScript, Rust, PHP, FastAPI, Django, Laravel, SQLAlchemy, TDD, DDD, DI |

Reviewer chuyên biệt tự động được kích hoạt (summon) khi confidence stack vượt ngưỡng (mặc định 0.6).

---

## 4. Điều phối Pipeline

### 4.1 Arc Pipeline 26 Phase

**Vấn đề**: Delivery code end-to-end (từ plan đến merged PR) gồm nhiều bước tuần tự với dependency, quality gate, và khả năng lỗi ở từng phase.

**Giải pháp**: Pipeline điều phối 26 phase:

```
Phase 1     FORGE              — Làm giàu plan bằng nghiên cứu
Phase 2     PLAN REVIEW        — 3 reviewer + circuit breaker
Phase 2.5   REFINEMENT         — Trích xuất concern
Phase 2.7   VERIFICATION       — Kiểm tra deterministic, không LLM
Phase 2.8   SEMANTIC CHECK     — Phân tích cross-model Codex
Phase 3     DESIGN EXTRACT     — Trích xuất ngữ cảnh thiết kế/Figma
Phase 4.5   TASK DECOMP        — Xác minh phân rã task
Phase 5     WORK               — Swarm implementation
Phase 5.3   DESIGN VERIFY      — Xác minh implementation theo thiết kế
Phase 5.5   GAP ANALYSIS       — Tuân thủ plan-to-code (deterministic)
Phase 5.6   CODEX GAP          — Phát hiện gap cross-model
Phase 5.8   GAP FIX            — Team tự sửa gap
Phase 5.9   GOLDMASK VERIFY    — Xác minh blast-radius
Phase 6     CODE REVIEW        — Roundtable Circle (--deep)
Phase 6.5   GOLDMASK CORR      — Tổng hợp investigation
Phase 7     MEND               — Sửa finding song song
Phase 7.5   VERIFY MEND        — Gate hội tụ (thích ứng)
Phase 7.6   DESIGN ITERATE     — Lặp cải tiến thiết kế
Phase 7.7   TEST               — Test 3 tầng theo diff
Phase 7.8   TEST CRITIQUE      — Phân tích coverage gap
Phase 8.5   PRE-SHIP           — Kiểm tra validation
Phase 8.55  RELEASE CHECK      — Kiểm tra CHANGELOG + breaking changes
Phase 9     SHIP               — Tạo PR
Phase 9.1   BOT REVIEW         — Chờ bot review bên ngoài
Phase 9.2   PR COMMENTS        — Giải quyết finding bot
Phase 9.5   MERGE              — Rebase + squash merge
```

Mỗi phase kích hoạt team mới với **giới hạn tool** và **ngân sách thời gian** riêng.

### 4.2 Checkpoint-Resume System

**Vấn đề**: Pipeline 26 phase chạy 30-90 phút chắc chắn gặp gián đoạn.

**Giải pháp**: Checkpoint bền vững tại `.claude/arc/{id}/checkpoint.json`:
- Lưu sau mỗi phase với **SHA-256 hash** xác minh tính toàn vẹn artifact
- Versioning schema tự migrate (v2 → v6)
- `PHASE_ORDER` array định nghĩa thứ tự chạy (đánh số không tuần tự cho tương thích ngược)
- Resume với `--resume` bỏ qua phase đã xong và xác minh hash

### 4.3 Stop-Hook Loop Pattern

**Vấn đề**: Batch operation (arc-batch, arc-hierarchy, arc-issues) cần chạy nhiều arc run tuần tự.

**Giải pháp**: Tận dụng event `Stop` hook để tạo vòng lặp bền vững:
1. State file theo dõi tiến độ: plan index, completed, failed
2. Khi arc run xong, Stop hook đọc state, tăng index, **inject prompt arc tiếp theo** qua blocking JSON
3. Tạo vòng lặp không cần subprocess management
4. Session isolation guard đảm bảo mỗi loop thuộc session chủ sở hữu

### 4.4 Bisection Algorithm for Mend

**Vấn đề**: Khi mend áp dụng fix từ nhiều Ash và ward check thất bại, không rõ fix nào gây lỗi.

**Giải pháp**: Tìm kiếm nhị phân trên output fixer:
1. Sau khi tất cả fixer xong, chạy ward check
2. Nếu ward thất bại: chia đôi file đã sửa
3. Áp fix từng nửa riêng, chạy lại ward
4. Đệ quy thu hẹp đến fix gây lỗi
5. Chỉ áp fix pass; đánh dấu fix lỗi là FAILED

### 4.5 Phase Order Execution Model

**Vấn đề**: Qua 200+ commit, phase được thêm, xoá, đổi thứ tự. Đánh số tuần tự sẽ phá tương thích checkpoint.

**Giải pháp**: Đánh số phase không tuần tự với mảng `PHASE_ORDER`:
- Phase ID là định danh ổn định (1, 2, 2.5, 2.7, 5, 5.5, 5.6, 5.8, 5.7, v.v.)
- `PHASE_ORDER` array định nghĩa thứ tự chạy thực
- Thứ tự không đơn điệu là cố ý: Phase 5.8 (GAP FIX) chạy TRƯỚC Phase 5.7 (GOLDMASK) vì gap fix phải xong trước phân tích blast-radius

---

## 5. Trí tuệ Planning

### 5.1 Forge Gaze (Chọn Agent theo Topic)

**Vấn đề**: Enrichment plan cần agent chuyên biệt khác nhau cho từng section. Chọn thủ công không scale.

**Giải pháp**: Scoring keyword-overlap deterministic:
1. Mỗi agent có tập keyword topic
2. Title section plan được tokenize thành keyword
3. Score = keyword overlap + title bonus
4. Agent vượt ngưỡng (mặc định 0.30) được chọn
5. Cap: `max_per_section: 3`, `max_total_agents: 8`
6. Stack affinity bonus (0.2) cho agent khớp stack

Toàn bộ quá trình chọn **không tốn token** — hoàn toàn deterministic.

### 5.2 Solution Arena

**Vấn đề**: Planning agent hay đề xuất giải pháp đầu tiên khả dĩ mà không khám phá thay thế.

**Giải pháp**: Đánh giá cạnh tranh tại Phase 1.8:
1. Tạo 2-5 giải pháp thay thế
2. Deploy agent thách thức đối kháng:
   - **Devil's Advocate**: Phân tích failure mode
   - **Innovation Scout**: Đề xuất giải pháp mới lạ
3. Chấm điểm trên ma trận 6 chiều: Feasibility (20%), Complexity (15%), Risk (20%), Maintainability (20%), Performance (15%), Innovation (10%)
4. Phát hiện hội tụ cho điểm hoà yêu cầu user phân xử
5. Giải pháp champion đưa vào Phase 2 (Synthesize)

### 5.3 Plan Freshness Gate

**Vấn đề**: Plan viết từ lâu có thể tham chiếu file, function, pattern không còn tồn tại.

**Giải pháp**: Chấm điểm freshness trước khi arc chạy:
1. Plan lưu `git_sha` trong frontmatter
2. Tính drift: `git rev-list --count {plan_sha}..HEAD`
3. Score tỷ lệ nghịch với khoảng cách commit
4. Hai ngưỡng: `warn_threshold: 0.7` (cảnh báo) và `block_threshold: 0.4` (chặn arc)
5. Override với `--skip-freshness` khi có chủ đích

---

## 6. Phân tích tác động

### 6.1 Goldmask Three-Layer Impact Analysis

**Vấn đề**: Trước khi thay đổi, team cần hiểu: CÁI GÌ sẽ hỏng (dependency), TẠI SAO code được viết vậy (intent), MỨC ĐỘ RỦI RO ra sao (lịch sử churn).

**Giải pháp**: Ba lớp phân tích trực giao:

| Lớp | Câu hỏi | Agent | Phương pháp |
|-----|---------|-------|------------|
| **Impact** | CÁI GÌ thay đổi? | 5 Haiku tracer | Trace dependency qua data, API, business, event, config |
| **Wisdom** | TẠI SAO viết vậy? | 1 Sonnet | Git blame archaeology + phân loại intent + caution scoring |
| **Lore** | RỦI RO thế nào? | 1 Haiku | Git analysis: churn metrics, co-change clustering, ownership |

Output: `GOLDMASK.md`, `findings.json`, `risk-map.json`.

**Tích hợp toàn diện**: Goldmask chạy trong 6 workflow: Devise (predictive), Forge (boost Gaze), Inspect (gap prioritization), Mend (risk context), Arc (phase 5.7 + 6.5), Standalone.

### 6.2 Collateral Damage Detection

**Vấn đề**: Dependency bậc 1 nhìn thấy được, nhưng thay đổi thường lan truyền qua quan hệ bậc 2, bậc 3.

**Giải pháp**: Goldmask Coordinator tổng hợp finding từ 7-8 tracer để phát hiện:
- **Effect bậc 2**: Thay đổi module A ảnh hưởng B, B ảnh hưởng C
- **Risk chain amplification**: File CRITICAL phụ thuộc file CRITICAL khác
- **Ownership gap**: File single-author mà author không còn active
- **Co-change clustering**: File thường thay đổi cùng nhau nhưng không liên kết trực tiếp

---

## 7. Quản lý Context

### 7.1 Context Weaving (Hệ thống 4 lớp)

**Vấn đề**: Session đa agent chạy lâu tích luỹ context cho đến khi window tràn và chất lượng giảm.

**Giải pháp**: Bốn lớp phòng thủ:

| Lớp | Trigger | Hành động |
|-----|---------|----------|
| **Overflow Prevention** | Trước spawn agent | Glyph Budget: file-only output, pre-summon planning |
| **Context Rot Prevention** | Trong execution | Instruction anchoring, thứ tự đọc |
| **Compression** | Message vượt ngưỡng | Session summary nén turn trước |
| **Filesystem Offloading** | Output vượt ngưỡng inline | Ghi ra `tmp/` với summary reference |

**Context Critical Guard** chặn TeamCreate/Task khi context còn 25%.

### 7.2 Compaction Resilience

**Vấn đề**: Claude Code tự compact conversation khi gần hết context. Team state, task list có thể bị mất.

**Giải pháp**: Hai hook phối hợp:
1. **`pre-compact-checkpoint.sh`**: Lưu team state trước compaction
2. **`session-compact-recovery.sh`**: Inject lại checkpoint sau compaction
3. Correlation guard xác minh team còn tồn tại
4. One-time injection: xoá checkpoint sau khi dùng

---

## 8. Bộ nhớ & Tri thức

### 8.1 Rune Echoes (Bộ nhớ Agent 5 tầng)

**Vấn đề**: Agent phát hiện lại cùng pattern, mắc cùng lỗi, học lại convention dự án qua các session.

**Giải pháp**: Bộ nhớ bền vững trong `.claude/echoes/{role}/MEMORY.md` với 5 tầng:

| Tầng | Độ bền | Pruning | Tạo bởi |
|------|--------|---------|---------|
| **Etched** | Vĩnh viễn | Không tự prune | Quyết định kiến trúc đã xác minh |
| **Notes** | Vĩnh viễn | Không tự prune | User tạo qua `/rune:echoes remember` |
| **Inscribed** | Dài hạn | 90 ngày không tham chiếu | Pattern review/audit confidence cao |
| **Observations** | Trung hạn | 60 ngày (tự promote sau 3 lần ref) | Quan sát session |
| **Traced** | Ngắn hạn | 30 ngày | Ghi chú tạm session |

Pruning đa yếu tố: importance (40%) x relevance (30%) x recency (30%).

### 8.2 Echo Search với FTS5

**Vấn đề**: Hàng trăm echo entry, tìm entry phù hợp cần nhiều hơn quét file.

**Giải pháp**: SQLite FTS5 full-text search qua MCP server:
- BM25 ranking làm tín hiệu relevance cơ sở
- **Scoring tổng hợp 5 yếu tố**: BM25 + importance tier + recency + file proximity + access frequency
- **Auto-reindex theo dirty signal**: Hook ghi marker khi echo file thay đổi; server tự reindex trước search tiếp theo
- Tính năng nâng cao (opt-in): semantic group expansion, query decomposition, Haiku reranking

### 8.3 Remembrance Channel

**Vấn đề**: Một số learning quan trọng đến mức cần truy cập ngoài session agent — trong tài liệu dễ đọc.

**Giải pháp**: Echo ETCHED với confidence cao và 2+ session tham chiếu được promote thành tài liệu trong `docs/solutions/`. Tài liệu bảo mật yêu cầu `verified_by: human` trước khi promote.

---

## 9. An toàn Session & Vòng đời

### 9.1 Session Isolation

**Vấn đề**: Nhiều session Claude Code trên cùng repo không được can thiệp lẫn nhau.

**Giải pháp**: Ba trường ownership trên tất cả state file:
- `config_dir` — CLAUDE_CONFIG_DIR đã resolve (cách ly installation)
- `owner_pid` — PID process Claude Code qua `$PPID` (cách ly session)
- `session_id` — CLAUDE_SESSION_ID (diagnostic)

Mọi hook script phải: kiểm tra `config_dir` khớp → kiểm tra `owner_pid` với `kill -0` → bỏ qua nếu thuộc session khác đang sống → dọn dẹp nếu thuộc session đã chết.

### 9.2 Team Lifecycle Guards

**Vấn đề**: Agent team có thể bị orphan (session crash, user ngắt), chặn workflow tương lai.

**Giải pháp**: Hệ thống 4 hook:

| Hook | Mã | Mục đích |
|------|-----|---------|
| `enforce-team-lifecycle.sh` | TLC-001 | Validate tên team, phát hiện team cũ (30 phút), dọn orphan |
| `verify-team-cleanup.sh` | TLC-002 | Xác minh xoá thư mục team, báo zombie |
| `session-team-hygiene.sh` | TLC-003 | Quét orphan khi start/resume session |
| `stamp-team-session.sh` | TLC-004 | Ghi marker `.session` cho verification ownership |

### 9.3 Nonce Validation

**Vấn đề**: TOME finding từ session review này có thể bị mend session khác tiêu thụ nhầm.

**Giải pháp**: Nonce theo session nhúng trong TOME finding. Mend chỉ trích xuất finding với nonce khớp qua regex. Chống nhiễm finding cross-session.

---

## 10. Hạ tầng Enforcement

### 10.1 Security Enforcement Hooks

**Vấn đề**: Review agent phải read-only. Mend fixer chỉ được sửa file được gán. Gap fixer không được chạm path nhạy cảm.

**Giải pháp**: Các PreToolUse hook:

| Hook | Mã | Enforcement |
|------|-----|------------|
| `enforce-readonly.sh` | SEC-001 | Chặn Write/Edit/Bash cho review Ash |
| `validate-mend-fixer-paths.sh` | SEC-MEND-001 | Chặn mend fixer ghi ngoài nhóm file được gán |
| `validate-gap-fixer-paths.sh` | SEC-GAP-001 | Chặn gap fixer ghi vào `.claude/`, `.github/`, CI YAML, `.env` |

### 10.2 Fidelity Enforcement Hooks

**Vấn đề**: Agent có thể phát triển anti-pattern: busy-wait polling, cú pháp shell không tương thích zsh, spawn agent ngoài team context.

**Giải pháp**: Hook phát hiện pattern chặn tool call:

| Hook | Mã | Pattern phát hiện | Hành động |
|------|-----|------------------|----------|
| `enforce-polling.sh` | POLL-001 | `sleep N && echo check` | Chặn — phải dùng TaskList |
| `enforce-zsh-compat.sh` | ZSH-001 | 5 anti-pattern zsh | Auto-fix |
| `enforce-teams.sh` | ATE-1 | `Task` không có `team_name` | Chặn — chống context explosion |

### 10.3 Quality Gate Hooks

**Vấn đề**: Agent có thể đánh dấu task hoàn thành sớm mà không tạo output cần thiết.

**Giải pháp**:
- **`on-task-completed.sh`**: Ghi signal file + chạy **haiku-model quality gate** validate tính hợp lệ hoàn thành
- **`on-teammate-idle.sh`**: Validate teammate đã ghi output file + có Seal marker (hard gate)

---

## Thống kê tổng hợp

| Danh mục | Số lượng |
|----------|---------|
| Tổng giải pháp kỹ thuật | 30 |
| Hook scripts | 28 |
| Agent chuyên biệt | 90 |
| Skills | 43 |
| Phase pipeline arc | 26 |
| Tier hội tụ review | 3 |
| Lớp phân tích tác động | 3 |
| Tầng memory | 5 |
| Reviewer chuyên stack | 11 |
| Enforcement hook | 8 |

Các giải pháp này phát triển lặp đi lặp lại qua 200+ commit, mỗi giải pháp giải quyết một failure mode thực tế được phát hiện trong quá trình sử dụng. Nguyên tắc xuyên suốt: **coi output agent là không đáng tin**, **enforce chất lượng ở mọi ranh giới**, **cách ly session khỏi nhau**, **phục hồi từ crash một cách duyên dáng**, và **tối thiểu chi phí token qua tiền xử lý deterministic**.
