//! Post-arc recovery for torrent watchdog.
//!
//! After an arc completes (or fails), the git working tree may be in various
//! states: uncommitted changes on the wrong branch, unpushed commits, missing
//! PRs, or git conflicts. This module detects those states and attempts
//! automated recovery — either via direct git commands (for stash/branch
//! operations) or by sending recovery prompts to Claude Code via tmux.
//!
//! # Safety Invariants
//!
//! - NEVER commit directly to main/master during recovery.
//! - NEVER delete branches during recovery — always preserve work.
//! - NEVER call `git stash drop` — on pop conflict, git preserves the stash
//!   automatically. We clean up with `git checkout -- .` instead.

use std::process::Command;
use std::thread;
use std::time::Duration;

use color_eyre::eyre::Result;

use crate::checkpoint::Checkpoint;
use crate::tmux::Tmux;

/// Default timeout for recovery operations (2 minutes).
const RECOVERY_TIMEOUT_SECS: u64 = 120;

/// Post-arc recovery engine.
///
/// Detects git state anomalies after an arc run completes and attempts
/// automated recovery. Uses direct `Command::new("git")` for deterministic
/// stash/branch operations (D25/D26) and `Tmux::send_keys` for operations
/// that benefit from Claude's judgment (D11-D14 commit/push/PR).
pub struct PostArcRecovery {
    /// Maximum time to wait for a recovery prompt to complete.
    pub recovery_timeout: Duration,
}

/// Branch context resolved before any git recovery action.
///
/// Captures a snapshot of the current git state so that recovery decisions
/// are based on a consistent view — not re-queried between steps.
#[derive(Debug, Clone)]
pub struct BranchContext {
    /// Current branch from `git branch --show-current`.
    pub current_branch: String,
    /// Expected branch resolved from checkpoint or plan slug.
    pub expected_branch: String,
    /// Whether current_branch is main or master.
    pub is_main: bool,
    /// Whether current_branch matches expected_branch.
    pub is_correct: bool,
    /// Whether `git status --porcelain` reports changes.
    pub has_changes: bool,
}

/// Detected post-arc state, determining which recovery path to take.
#[derive(Debug)]
pub enum PostArcState {
    /// All done — PR merged, nothing to recover.
    FullyComplete,
    /// D25: Uncommitted changes sitting on main — needs stash + branch + apply.
    UncommittedOnMain(BranchContext),
    /// D26: Uncommitted changes on the wrong feature branch — needs stash + switch.
    UncommittedOnWrongBranch(BranchContext),
    /// D11: Uncommitted changes on the correct branch — send commit prompt.
    UncommittedChanges,
    /// D12: All committed but not pushed — send push prompt.
    UnpushedCommits,
    /// D13: Pushed but no PR created — send PR prompt.
    NoPullRequest,
    /// D14: PR exists but not merged — send merge/wait prompt.
    UnmergedPR(String),
    /// D15: Git conflict detected — needs operator intervention.
    GitConflict(String),
    /// Nothing happened — no changes, no commits.
    NoWorkDone,
}

/// Outcome of a recovery attempt.
#[derive(Debug)]
pub enum RecoveryResult {
    /// Recovery completed successfully.
    Recovered,
    /// Some recovery steps completed; details describe remaining work.
    PartialRecovery(String),
    /// Recovery failed entirely.
    Failed(String),
    /// Stash pop had conflicts — stash preserved, ref logged for operator.
    StashPreserved(String),
    /// Conflict requires human intervention.
    ConflictNeedsOperator,
}

/// Errors during stash + branch switch (D25/D26).
///
/// These are recoverable in the sense that the working tree is left in a
/// known state — but the automated recovery cannot proceed further.
#[derive(Debug)]
pub enum RecoveryError {
    /// `git stash push` failed (perhaps no changes to stash).
    StashFailed(String),
    /// Branch checkout or creation failed.
    CheckoutFailed(String),
    /// `git stash pop` had merge conflicts — stash is NOT dropped.
    /// Working tree cleaned with `git checkout -- .`.
    StashPopConflict(String),
    /// Git state was not what we expected.
    UnexpectedState(String),
}

impl std::fmt::Display for RecoveryError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RecoveryError::StashFailed(msg) => write!(f, "stash failed: {msg}"),
            RecoveryError::CheckoutFailed(msg) => write!(f, "checkout failed: {msg}"),
            RecoveryError::StashPopConflict(msg) => write!(f, "stash pop conflict: {msg}"),
            RecoveryError::UnexpectedState(msg) => write!(f, "unexpected state: {msg}"),
        }
    }
}

impl PostArcRecovery {
    /// Create a new recovery engine with default timeout.
    pub fn new() -> Self {
        Self {
            recovery_timeout: Duration::from_secs(RECOVERY_TIMEOUT_SECS),
        }
    }

    /// Detect the post-arc state by examining git working tree.
    ///
    /// Runs direct git commands (not via tmux) to get a reliable snapshot
    /// of branch, changes, commits, and PR status.
    pub fn check_post_arc_state(
        &self,
        plan_slug: &str,
        checkpoint: Option<&Checkpoint>,
    ) -> PostArcState {
        let ctx = match self.build_branch_context(plan_slug, checkpoint) {
            Some(ctx) => ctx,
            None => return PostArcState::NoWorkDone,
        };

        // Check for git conflicts first (highest priority).
        if let Some(conflict) = detect_git_conflict() {
            return PostArcState::GitConflict(conflict);
        }

        // If there are uncommitted changes, check branch correctness.
        if ctx.has_changes {
            if ctx.is_main {
                return PostArcState::UncommittedOnMain(ctx);
            }
            if !ctx.is_correct {
                return PostArcState::UncommittedOnWrongBranch(ctx);
            }
            return PostArcState::UncommittedChanges;
        }

        // No uncommitted changes — check further in the pipeline.
        if has_unpushed_commits() {
            return PostArcState::UnpushedCommits;
        }

        // Check for PR status via `gh pr view`.
        match get_pr_status() {
            PrStatus::None => {
                // If we have commits on a feature branch, PR is missing.
                if !ctx.is_main && has_any_commits_ahead_of_main() {
                    return PostArcState::NoPullRequest;
                }
                PostArcState::NoWorkDone
            }
            PrStatus::Open(url) => PostArcState::UnmergedPR(url),
            PrStatus::Merged => PostArcState::FullyComplete,
        }
    }

    /// Attempt automated recovery based on the detected state.
    ///
    /// For D25/D26 (stash+branch), uses `Command::new("git")` directly.
    /// For D11-D14 (commit/push/PR), uses `Tmux::send_keys` to Claude Code.
    pub fn attempt_recovery(
        &self,
        session_id: &str,
        state: PostArcState,
    ) -> RecoveryResult {
        match state {
            PostArcState::FullyComplete => RecoveryResult::Recovered,
            PostArcState::NoWorkDone => RecoveryResult::Failed("no work to recover".into()),

            // D25: Changes on main — stash, create/switch branch, pop.
            PostArcState::UncommittedOnMain(ctx) => {
                match stash_and_switch_branch(&ctx.expected_branch, true) {
                    Ok(()) => {
                        // Changes now on correct branch — send commit prompt via tmux.
                        send_recovery_prompt(
                            session_id,
                            "git add -A && git commit -m 'recovered: apply stashed changes'",
                        );
                        RecoveryResult::PartialRecovery(format!(
                            "stashed and switched to {}, commit prompt sent",
                            ctx.expected_branch
                        ))
                    }
                    Err(RecoveryError::StashPopConflict(ref_id)) => {
                        RecoveryResult::StashPreserved(ref_id)
                    }
                    Err(e) => RecoveryResult::Failed(e.to_string()),
                }
            }

            // D26: Changes on wrong branch — stash, switch to correct branch, pop.
            PostArcState::UncommittedOnWrongBranch(ctx) => {
                match stash_and_switch_branch(&ctx.expected_branch, false) {
                    Ok(()) => {
                        send_recovery_prompt(
                            session_id,
                            "git add -A && git commit -m 'recovered: apply stashed changes'",
                        );
                        RecoveryResult::PartialRecovery(format!(
                            "stashed and switched to {}, commit prompt sent",
                            ctx.expected_branch
                        ))
                    }
                    Err(RecoveryError::StashPopConflict(ref_id)) => {
                        RecoveryResult::StashPreserved(ref_id)
                    }
                    Err(e) => RecoveryResult::Failed(e.to_string()),
                }
            }

            // D11: Uncommitted changes on correct branch — ask Claude to commit.
            PostArcState::UncommittedChanges => {
                send_recovery_prompt(session_id, "Please commit all pending changes");
                wait_for_recovery(session_id, self.recovery_timeout, "commit")
            }

            // D12: Unpushed commits — ask Claude to push.
            PostArcState::UnpushedCommits => {
                send_recovery_prompt(session_id, "Please push your commits");
                wait_for_recovery(session_id, self.recovery_timeout, "push")
            }

            // D13: No PR — ask Claude to create one.
            PostArcState::NoPullRequest => {
                send_recovery_prompt(session_id, "Please create a pull request");
                wait_for_recovery(session_id, self.recovery_timeout, "pr creation")
            }

            // D14: PR exists but unmerged — log for operator.
            PostArcState::UnmergedPR(url) => {
                RecoveryResult::PartialRecovery(format!("PR exists but unmerged: {url}"))
            }

            // D15: Git conflict — cannot auto-resolve safely.
            PostArcState::GitConflict(details) => {
                tracing_log(&format!("git conflict detected: {details}"));
                RecoveryResult::ConflictNeedsOperator
            }
        }
    }

    /// Build a `BranchContext` snapshot of the current git state.
    fn build_branch_context(
        &self,
        plan_slug: &str,
        checkpoint: Option<&Checkpoint>,
    ) -> Option<BranchContext> {
        let current_branch = git_current_branch()?;
        let expected_branch = resolve_expected_branch(plan_slug, checkpoint, None);
        let is_main = current_branch == "main" || current_branch == "master";
        let is_correct = current_branch == expected_branch;
        let has_changes = git_has_changes();

        Some(BranchContext {
            current_branch,
            expected_branch,
            is_main,
            is_correct,
            has_changes,
        })
    }
}

// ---------------------------------------------------------------------------
// Branch resolution
// ---------------------------------------------------------------------------

/// Resolve the expected branch name for a plan, using a 4-tier fallback:
///
/// 1. Checkpoint branch field (most reliable — set by arc itself)
/// 2. Local branch matching the plan slug (`git branch --list "*{slug}*"`)
/// 3. Derived from plan filename convention
/// 4. Generated name with compact timestamp
///
/// The plan slug is typically the plan filename without the `.md` extension,
/// e.g. `"2026-03-19-feat-auth-plan"`.
pub fn resolve_expected_branch(
    plan_slug: &str,
    checkpoint: Option<&Checkpoint>,
    loop_state_branch: Option<&str>,
) -> String {
    // Tier 1: Arc loop state branch field (most reliable — set at arc init).
    // The loop state file (.rune/arc-phase-loop.local.md) records the branch
    // created by arc's branch strategy. The checkpoint itself doesn't have
    // a branch field, but the loop state does.
    if let Some(branch) = loop_state_branch {
        if !branch.is_empty() {
            return branch.to_string();
        }
    }

    // Tier 1b: Check checkpoint's config_dir for active arc loop state.
    // This is a fallback for when loop_state_branch is not passed.
    let _ = checkpoint; // Checkpoint doesn't have branch field yet

    // Tier 2: Find existing local branch matching the plan slug.
    if let Some(branch) = find_branch_matching(plan_slug) {
        return branch;
    }

    // Tier 3: Generate branch name from plan slug using arc's naming convention.
    format!("rune/arc-{}", plan_slug)
}

/// Search local branches for one matching the plan slug.
///
/// Uses `git branch --list "*{slug}*"` to find candidates. Returns the first
/// match (stripped of whitespace and `*` prefix from current-branch marker).
fn find_branch_matching(plan_slug: &str) -> Option<String> {
    let pattern = format!("*{}*", plan_slug);
    let output = Command::new("git")
        .args(["branch", "--list", &pattern])
        .output()
        .ok()?;

    if !output.status.success() {
        return None;
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    stdout
        .lines()
        .next()
        .map(|line| line.trim().trim_start_matches("* ").trim().to_string())
        .filter(|s| !s.is_empty())
}

// ---------------------------------------------------------------------------
// Git state queries (direct Command::new, not tmux)
// ---------------------------------------------------------------------------

/// Get the current branch name, or None if in detached HEAD state.
fn git_current_branch() -> Option<String> {
    let output = Command::new("git")
        .args(["branch", "--show-current"])
        .output()
        .ok()?;

    if !output.status.success() {
        return None;
    }

    let branch = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if branch.is_empty() {
        None
    } else {
        Some(branch)
    }
}

/// Check if the working tree has uncommitted changes.
fn git_has_changes() -> bool {
    Command::new("git")
        .args(["status", "--porcelain"])
        .output()
        .map(|o| !String::from_utf8_lossy(&o.stdout).trim().is_empty())
        .unwrap_or(false)
}

/// Detect git conflicts (merge markers in the working tree).
fn detect_git_conflict() -> Option<String> {
    let output = Command::new("git")
        .args(["diff", "--check"])
        .output()
        .ok()?;

    // `git diff --check` exits non-zero if conflict markers are found.
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let stdout = String::from_utf8_lossy(&output.stdout);
        let details = if !stdout.trim().is_empty() {
            stdout.trim().to_string()
        } else {
            stderr.trim().to_string()
        };
        if details.contains("conflict") || details.contains("<<<<") {
            return Some(details);
        }
    }
    None
}

/// Check if there are commits not yet pushed to the remote.
fn has_unpushed_commits() -> bool {
    // `git log @{u}..HEAD` shows commits ahead of upstream.
    // If the upstream isn't set, this fails — treat as "no unpushed".
    Command::new("git")
        .args(["log", "--oneline", "@{u}..HEAD"])
        .output()
        .map(|o| o.status.success() && !String::from_utf8_lossy(&o.stdout).trim().is_empty())
        .unwrap_or(false)
}

/// Check if there are any commits ahead of main (on a feature branch).
fn has_any_commits_ahead_of_main() -> bool {
    Command::new("git")
        .args(["log", "--oneline", "main..HEAD"])
        .output()
        .map(|o| o.status.success() && !String::from_utf8_lossy(&o.stdout).trim().is_empty())
        .unwrap_or(false)
}

/// PR status from `gh pr view`.
enum PrStatus {
    None,
    Open(String),
    Merged,
}

/// Query PR status for the current branch via `gh pr view`.
fn get_pr_status() -> PrStatus {
    let output = match Command::new("gh")
        .args(["pr", "view", "--json", "state,url"])
        .output()
    {
        Ok(o) if o.status.success() => o,
        _ => return PrStatus::None,
    };

    let stdout = String::from_utf8_lossy(&output.stdout);
    let text = stdout.to_lowercase();

    if text.contains("\"merged\"") {
        return PrStatus::Merged;
    }

    // Extract URL from JSON using serde_json (handles escaped quotes correctly).
    if let Ok(json) = serde_json::from_str::<serde_json::Value>(&stdout) {
        if let Some(url) = json.get("url").and_then(|v| v.as_str()) {
            return PrStatus::Open(url.to_string());
        }
        // JSON parsed but no URL field — check state for open
        if json.get("state").and_then(|v| v.as_str()) == Some("OPEN") {
            return PrStatus::Open("(url unavailable)".into());
        }
    }

    PrStatus::None
}

// ---------------------------------------------------------------------------
// Git stash + branch operations (D25/D26) — direct Command::new
// ---------------------------------------------------------------------------

/// Stash current changes, switch to the expected branch, and pop the stash.
///
/// # Safety
///
/// - Uses `Command::new("git")` directly for deterministic, testable execution.
/// - NEVER calls `git stash drop` — on pop conflict, git preserves the stash.
/// - On stash pop conflict: runs `git checkout -- .` to discard conflicted
///   apply (stash preserved), logs warning, and returns `StashPopConflict`.
/// - The `create_branch` flag controls whether to `checkout -b` (new branch)
///   or `checkout` (existing branch).
///
/// # Arguments
///
/// * `expected_branch` — The branch to switch to (created if `create_branch` is true).
/// * `create_branch` — If true, create the branch (`git checkout -b`).
// SAFETY: This function modifies the git working tree (stash push, checkout, stash pop).
// On any failure, the stash is preserved and the working tree is cleaned up.
fn stash_and_switch_branch(
    expected_branch: &str,
    create_branch: bool,
) -> Result<(), RecoveryError> {
    // Step 1: Stash current changes.
    // SAFETY: `git stash push -m` is non-destructive — changes move to stash reflog.
    let stash_msg = format!("torrent-recovery: stash for branch {expected_branch}");
    let stash = Command::new("git")
        .args(["stash", "push", "-m", &stash_msg])
        .output()
        .map_err(|e| RecoveryError::StashFailed(e.to_string()))?;

    if !stash.status.success() {
        let stderr = String::from_utf8_lossy(&stash.stderr);
        return Err(RecoveryError::StashFailed(stderr.trim().to_string()));
    }

    // Record stash ref for operator reference.
    let stash_ref = get_stash_ref();
    tracing_log(&format!(
        "recovery: stashed changes as {stash_ref} for branch {expected_branch}"
    ));

    // Step 2: Switch to the expected branch.
    // SAFETY: `git checkout [-b]` is safe — no data loss, just branch pointer change.
    let checkout_args = if create_branch {
        vec!["checkout", "-b", expected_branch]
    } else {
        vec!["checkout", expected_branch]
    };

    let checkout = Command::new("git")
        .args(&checkout_args)
        .output()
        .map_err(|e| RecoveryError::CheckoutFailed(e.to_string()))?;

    if !checkout.status.success() {
        let stderr = String::from_utf8_lossy(&checkout.stderr);
        return Err(RecoveryError::CheckoutFailed(stderr.trim().to_string()));
    }

    // Step 3: Pop the stash.
    // SAFETY: If pop fails (conflict), git does NOT drop the stash entry.
    // We clean up with `git checkout -- .` to discard the conflicted apply.
    let pop = Command::new("git")
        .args(["stash", "pop"])
        .output()
        .map_err(|e| RecoveryError::UnexpectedState(e.to_string()))?;

    if !pop.status.success() {
        let _stderr = String::from_utf8_lossy(&pop.stderr);

        // P1.3: After stash pop conflict, run `git checkout -- .` to discard
        // the conflicted apply. The stash is preserved (git doesn't drop on
        // failed pop), so operator can manually apply later.
        // SAFETY: `git checkout -- .` discards all working tree changes.
        // This is intentional — the conflicted merge markers must be removed
        // to leave the repo in a clean state for the next plan.
        let cleanup = Command::new("git")
            .args(["checkout", "--", "."])
            .output();

        if let Err(e) = &cleanup {
            tracing_log(&format!("recovery: git checkout -- . failed: {e}"));
        }

        tracing_log(&format!(
            "recovery: stash pop conflict on {expected_branch}, stash preserved as {stash_ref}. \
             Working tree cleaned with git checkout -- ."
        ));

        return Err(RecoveryError::StashPopConflict(stash_ref));
    }

    Ok(())
}

/// Get the most recent stash ref (e.g., "stash@{0}") for logging.
fn get_stash_ref() -> String {
    Command::new("git")
        .args(["stash", "list", "-1"])
        .output()
        .ok()
        .and_then(|o| {
            let s = String::from_utf8_lossy(&o.stdout).trim().to_string();
            if s.is_empty() { None } else { Some(s) }
        })
        .unwrap_or_else(|| "stash@{0}".into())
}

// ---------------------------------------------------------------------------
// Recovery prompts (D11-D14) — via Tmux::send_keys
// ---------------------------------------------------------------------------

/// Send a recovery prompt to Claude Code via tmux.
///
/// Uses `Tmux::send_keys` which handles the Ink autocomplete workaround
/// (Escape+delay+Enter). Best-effort — logs but does not fail on error.
fn send_recovery_prompt(session_id: &str, prompt: &str) {
    if let Err(e) = Tmux::send_keys(session_id, prompt) {
        tracing_log(&format!("recovery: send_keys failed: {e}"));
    }
}

/// Wait for a recovery operation to complete by polling tmux pane output.
///
/// Checks every 5 seconds for signs that the operation completed.
/// Returns after timeout or when no new output is detected (idle).
fn wait_for_recovery(
    session_id: &str,
    timeout: Duration,
    operation: &str,
) -> RecoveryResult {
    let start = std::time::Instant::now();
    let poll_interval = Duration::from_secs(5);
    let mut last_hash: Option<u64> = None;
    let mut idle_count = 0u32;

    while start.elapsed() < timeout {
        thread::sleep(poll_interval);

        // Check if session still exists.
        if !Tmux::has_session(session_id) {
            return RecoveryResult::Failed(format!(
                "tmux session disappeared during {operation}"
            ));
        }

        // Check for output changes via pane hash.
        let current_hash = Tmux::capture_pane_hash(session_id, 10);
        if current_hash == last_hash {
            idle_count += 1;
            // 3 consecutive idle polls (15s) — assume operation completed or stalled.
            if idle_count >= 3 {
                return RecoveryResult::PartialRecovery(format!(
                    "{operation} prompt sent, output stabilized after {}s",
                    start.elapsed().as_secs()
                ));
            }
        } else {
            idle_count = 0;
            last_hash = current_hash;
        }
    }

    RecoveryResult::PartialRecovery(format!(
        "{operation} timed out after {}s",
        timeout.as_secs()
    ))
}

// ---------------------------------------------------------------------------
// Logging helper
// ---------------------------------------------------------------------------

/// Append a line to the torrent run log (best-effort).
///
/// Uses the JSONL run log from F5 if available, otherwise prints to stderr.
fn tracing_log(msg: &str) {
    tlog!(INFO, "[recovery] {msg}");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_resolve_expected_branch_with_no_checkpoint() {
        let branch = resolve_expected_branch("2026-03-19-feat-auth-plan", None, None);
        // Should either find a matching local branch or generate one.
        assert!(
            branch.contains("2026-03-19-feat-auth-plan"),
            "branch should contain plan slug: {branch}"
        );
    }

    #[test]
    fn test_recovery_error_display() {
        let err = RecoveryError::StashFailed("no local changes".into());
        assert_eq!(err.to_string(), "stash failed: no local changes");

        let err = RecoveryError::StashPopConflict("stash@{0}".into());
        assert!(err.to_string().contains("stash pop conflict"));
    }

    #[test]
    fn test_post_arc_recovery_new() {
        let recovery = PostArcRecovery::new();
        assert_eq!(recovery.recovery_timeout.as_secs(), 120);
    }
}
