# Contributing to hobnix/official

## Sign your commits (DCO)

Every commit needs a `Signed-off-by: Your Name <you@example.org>` line, which certifies the Developer Certificate of Origin
(https://developercertificate.org/). `git commit -s` adds it; for commits you already made: `git rebase --signoff origin/develop`.
CI (workflow `dco`) refuses a pull request with an unsigned commit. Contributions are accepted under the licence of the folder they go into:
MIT in `recipes/`, AGPL-3.0 everywhere else.

## Branches

- Start a branch `feature/<topic>` or `fix/<topic>` from `develop`; open the pull request against `develop` (the default branch).
- `main` holds what servers get and takes only a release pull request (`develop` into `main`, merge commit, no squash). There are no tags.
- A hotfix branches from `main`, goes into `main`, then back into `develop`.

## Writing a package

1. One folder per package under the folder of its kind (`recipes/`, `extensions/`, `capabilities/`) with a `package.toml`: `name` (= the
   folder), `version` (semver), `kind`, `title`, `title_de`, `requires_core` (the API level of the core helpers it uses). Add it to `index.toml`.
2. A recipe's `run.sh` is idempotent, built from the helpers of the core (`scripts/recipes/_lib.sh`), never prints raw command output, never
   reads a secret from argv or the environment, pins every download (version + sha256) and never opens a public route for an admin page.
3. Versions: a pull request does not raise a version. It carries the label `bump: minor` or `bump: major`, none = patch, at most one (CI
   refuses two). The workflow `prepare-release` on `develop` raises `version` in `package.toml` and `index.toml` together and opens a pull
   request into `develop`. On the release pull request the job `versions` fails for a package that changed since `main` without a higher version.
4. `pkg.py validate`, `pkg.py repo-check .` and `tests/run-all.sh` must pass (CI runs them against the core, see README.md).
5. Rust extensions ship a static musl program; only the release preparation and the release pull request may carry a program
   (`scripts/binary-check.py`, workflow `rust`). On `develop` a crate pins the SDK `hobnix-ext-sdk` by git `rev`. Before a release, change it to
   `tag = "vX.Y.Z"` of a core release that has what the crate uses, and update `Cargo.lock` (`cargo update -p hobnix-ext-sdk`) in its own pull
   request into `develop`: the core's `repo-check --release` refuses any other pin (ADR 0031). Run `prepare-release` after that merge.
