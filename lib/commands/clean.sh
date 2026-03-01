#!/usr/bin/env bash

# Clean command (remove prunable worktrees)

# Detect hosting provider with error messaging.
# Prints provider name on success; returns 1 on failure.
_clean_detect_provider() {
  local provider
  provider=$(detect_provider) || true
  if [ -n "$provider" ]; then
    printf "%s" "$provider"
    return 0
  fi

  local remote_url
  remote_url=$(git remote get-url origin 2>/dev/null || true)
  if [ -z "$remote_url" ]; then
    log_error "No remote URL configured for 'origin'"
  else
    # Sanitize URL to avoid leaking embedded credentials (e.g., https://token@host/...)
    local safe_url="${remote_url%%@*}"
    if [ "$safe_url" != "$remote_url" ]; then
      safe_url="<redacted>@${remote_url#*@}"
    fi
    log_error "Could not detect hosting provider from remote URL: $safe_url"
    log_info "Set manually: git gtr config set gtr.provider github  (or gitlab)"
  fi
  return 1
}

# Check if a worktree should be skipped during cleanup.
# Returns 0 if should skip, 1 if should process.
# Usage: _clean_should_skip <dir> <branch> [force_mode]
_clean_should_skip() {
  local dir="$1" branch="$2" force="${3:-0}"

  if [ -z "$branch" ] || [ "$branch" = "(detached)" ]; then
    log_warn "Skipping $dir (detached HEAD)"
    return 0
  fi

  if [ "$force" -eq 0 ]; then
    if ! git -C "$dir" diff --quiet 2>/dev/null || \
       ! git -C "$dir" diff --cached --quiet 2>/dev/null; then
      log_warn "Skipping $branch (has uncommitted changes, use --force)"
      return 0
    fi

    if [ -n "$(git -C "$dir" ls-files --others --exclude-standard 2>/dev/null)" ]; then
      log_warn "Skipping $branch (has untracked files, use --force)"
      return 0
    fi
  fi

  return 1
}

# Remove detached HEAD worktrees (orphaned after branch deletion)
# Usage: _clean_detached repo_root base_dir prefix yes_mode dry_run force_mode
_clean_detached() {
  local repo_root="$1" base_dir="$2" prefix="$3" yes_mode="$4" dry_run="$5" force_mode="$6"

  log_step "Checking for detached HEAD worktrees..."

  local removed=0 skipped=0

  for dir in "$base_dir/${prefix}"*; do
    [ -d "$dir" ] || continue

    local branch
    branch=$(current_branch "$dir") || true

    # Only process detached HEAD worktrees
    if [ -n "$branch" ] && [ "$branch" != "(detached)" ]; then
      continue
    fi

    # Check for uncommitted changes unless --force
    if [ "$force_mode" -eq 0 ]; then
      if ! git -C "$dir" diff --quiet 2>/dev/null || \
         ! git -C "$dir" diff --cached --quiet 2>/dev/null; then
        log_warn "Skipping $dir (detached HEAD with uncommitted changes, use --force)"
        skipped=$((skipped + 1))
        continue
      fi
      if [ -n "$(git -C "$dir" ls-files --others --exclude-standard 2>/dev/null)" ]; then
        log_warn "Skipping $dir (detached HEAD with untracked files, use --force)"
        skipped=$((skipped + 1))
        continue
      fi
    fi

    if [ "$dry_run" -eq 1 ]; then
      log_info "[dry-run] Would remove: $dir (detached HEAD)"
      removed=$((removed + 1))
    elif [ "$yes_mode" -eq 1 ] || prompt_yes_no "Remove detached worktree '$(basename "$dir")'?"; then
      log_step "Removing detached worktree: $(basename "$dir")"
      local remove_output
      if remove_output=$(git worktree remove "$dir" --force 2>&1); then
        log_info "Removed: $(basename "$dir")"
        removed=$((removed + 1))
      elif [[ "$remove_output" == *"is not a working tree"* ]]; then
        # Orphaned directory - worktree metadata already pruned, just rm
        if rm -rf "$dir" 2>/dev/null; then
          log_info "Removed orphaned directory: $(basename "$dir")"
          removed=$((removed + 1))
        else
          log_error "Failed to remove orphaned directory: $dir"
          skipped=$((skipped + 1))
        fi
      else
        log_error "Failed to remove: $dir"
        [ -n "$remove_output" ] && log_error "$remove_output"
        skipped=$((skipped + 1))
      fi
    else
      log_warn "Skipped: $(basename "$dir") (user declined)"
      skipped=$((skipped + 1))
    fi
  done

  echo ""
  if [ "$dry_run" -eq 1 ]; then
    log_info "Dry run complete. Would remove: $removed, Skipped: $skipped"
  else
    log_info "Detached cleanup complete. Removed: $removed, Skipped: $skipped"
  fi
}

# Remove worktrees whose PRs/MRs are merged (handles squash merges)
# Usage: _clean_merged repo_root base_dir prefix yes_mode dry_run force_mode
_clean_merged() {
  local repo_root="$1" base_dir="$2" prefix="$3" yes_mode="$4" dry_run="$5" force_mode="$6"

  log_step "Checking for worktrees with merged PRs/MRs..."

  local provider
  provider=$(_clean_detect_provider) || exit 1
  ensure_provider_cli "$provider" || exit 1

  log_step "Fetching from origin..."
  git fetch origin --prune 2>/dev/null || log_warn "Could not fetch from origin"

  local removed=0 skipped=0
  local main_branch
  main_branch=$(current_branch "$repo_root")

  for dir in "$base_dir/${prefix}"*; do
    [ -d "$dir" ] || continue

    local branch
    branch=$(current_branch "$dir") || true

    # Skip main repo branch silently (not counted)
    [ "$branch" = "$main_branch" ] && continue

    if _clean_should_skip "$dir" "$branch" "$force_mode"; then
      skipped=$((skipped + 1))
      continue
    fi

    # Check if branch has a merged PR/MR
    if check_branch_merged "$provider" "$branch"; then
      if [ "$dry_run" -eq 1 ]; then
        log_info "[dry-run] Would remove: $branch ($dir)"
        removed=$((removed + 1))
      elif [ "$yes_mode" -eq 1 ] || prompt_yes_no "Remove worktree and delete branch '$branch'?"; then
        log_step "Removing worktree: $branch"

        if ! run_hooks_in preRemove "$dir" \
          REPO_ROOT="$repo_root" \
          WORKTREE_PATH="$dir" \
          BRANCH="$branch"; then
          log_warn "Pre-remove hook failed for $branch, skipping"
          skipped=$((skipped + 1))
          continue
        fi

        if remove_worktree "$dir" "$force_mode"; then
          git branch -d "$branch" 2>/dev/null || git branch -D "$branch" 2>/dev/null || true
          removed=$((removed + 1))

          if ! run_hooks postRemove \
            REPO_ROOT="$repo_root" \
            WORKTREE_PATH="$dir" \
            BRANCH="$branch"; then
            log_warn "Post-remove hook failed for $branch"
          fi
        fi
      else
        log_warn "Skipped: $branch (user declined)"
        skipped=$((skipped + 1))
      fi
    fi
  done

  echo ""
  if [ "$dry_run" -eq 1 ]; then
    log_info "Dry run complete. Would remove: $removed, Skipped: $skipped"
  else
    log_info "Merged cleanup complete. Removed: $removed, Skipped: $skipped"
  fi
}

# shellcheck disable=SC2154  # _arg_* set by parse_args, _ctx_* set by resolve_*
cmd_clean() {
  local _spec
  _spec="--merged
--include-detached|-d
--force|-f
--yes|-y
--dry-run|-n"
  parse_args "$_spec" "$@"

  local merged_mode="${_arg_merged:-0}"
  local include_detached="${_arg_include_detached:-0}"
  local force_mode="${_arg_force:-0}"
  local yes_mode="${_arg_yes:-0}"
  local dry_run="${_arg_dry_run:-0}"

  log_step "Cleaning up stale worktrees..."

  # Run git worktree prune
  if git worktree prune 2>/dev/null; then
    log_info "Pruned stale worktree administrative files"
  fi

  resolve_repo_context || exit 1

  local repo_root="$_ctx_repo_root" base_dir="$_ctx_base_dir" prefix="$_ctx_prefix"

  if [ ! -d "$base_dir" ]; then
    log_info "No worktrees directory to clean"
    return 0
  fi

  # Find and remove empty directories
  local cleaned=0
  local empty_dirs
  empty_dirs=$(find "$base_dir" -maxdepth 1 -type d -empty 2>/dev/null | grep -Fxv "$base_dir" || true)

  if [ -n "$empty_dirs" ]; then
    while IFS= read -r dir; do
      if [ -n "$dir" ]; then
        if rmdir "$dir" 2>/dev/null; then
          cleaned=$((cleaned + 1))
          log_info "Removed empty directory: $(basename "$dir")"
        fi
      fi
    done <<EOF
$empty_dirs
EOF
  fi

  if [ "$cleaned" -gt 0 ]; then
    log_info "Cleanup complete ($cleaned director$([ "$cleaned" -eq 1 ] && echo 'y' || echo 'ies') removed)"
  else
    log_info "Cleanup complete (no empty directories found)"
  fi

  # --include-detached mode: remove detached HEAD worktrees (orphaned)
  if [ "$include_detached" -eq 1 ]; then
    _clean_detached "$repo_root" "$base_dir" "$prefix" "$yes_mode" "$dry_run" "$force_mode"
  fi

  # --merged mode: remove worktrees with merged PRs/MRs (handles squash merges)
  if [ "$merged_mode" -eq 1 ]; then
    _clean_merged "$repo_root" "$base_dir" "$prefix" "$yes_mode" "$dry_run" "$force_mode"
  fi
}