# Project working agreement

## Pull request delivery

The user requires new Codex conversation forks and development branches in this
project to deliver changes through pull requests to `main` (2026-10-31).

1. Inspect the working tree, branch and existing PRs before editing. Continue an
   existing PR for the same work. Use an isolated branch/worktree on E: when
   another active chat shares the checkout.
2. As soon as the first reviewable commit exists, push the work branch and open
   a **draft PR targeting `main`**. This is standing user authorization: create
   the PR without another confirmation. Push subsequent commits to the same PR.
3. Attach every created PR to the current Codex chat with `attach_artifact` when
   available, and provide its URL. Keep its title and description about the final
   behavior and actual validation status.
4. Run applicable checks remotely. Keep incomplete validation explicit; mark
   the PR ready when its checks pass. Complete authorized integration through
   the PR rather than directly pushing new work to `main`.

An unchanged fork or a branch already contained in `main` has no PR diff. Report
that state instead of creating empty or duplicate PRs. Creating a PR alone does
not authorize unrelated merges, releases or messages to other chats.

## Validation and local delivery

- Run tests, builds, probes, benchmarks, game launches and UI acceptance in
  remote CI or an isolated remote environment. Local source inspection and
  authorized installation are allowed; installation does not authorize testing.
- Reuse the existing private game-bundle release for remote game acceptance.
  Preserve its asset identity; upload another bundle only if game assets change.
- For authorized plugin updates, install verified remote artifacts locally after
  the game exits normally. Preserve configuration, saves and unrelated addons,
  and create a reversible backup. Keep the game closed during installation.
