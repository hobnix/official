<p align="center"><img src="https://raw.githubusercontent.com/hobnix/core/HEAD/.github/branding/banner@2x.webp" alt="hobnix" width="100%"></p>

# hobnix/official

The official packages of Hobnix, the NixOS home server (https://github.com/hobnix/core). One repository, three kinds of package, one signed
index (https://packages.hobnix.dev/official). Every package has one version, whatever its kind. Third-party and community packages live elsewhere (hobnix/community). It replaces the three repositories hobnix/recipes, hobnix/extensions and hobnix/capabilities (hobnix/core#1074).

## What is in it

| Folder | `kind` | What it is | Licence |
|---|---|---|---|
| `recipes/<name>/` | recipe | installs an app in its own container or VM | MIT (`recipes/LICENSE`) |
| `extensions/<name>/` | extension | an optional part of the server (commands, pages, jobs) | AGPL-3.0 |
| `capabilities/<name>/` | capability | a part of the NixOS configuration, vendored as a Nix module | AGPL-3.0 |
| `blueprints/<name>/` | blueprint | a ready-made set of packages and settings (so far `minimal`) | AGPL-3.0 |

Everything outside `recipes/` is AGPL-3.0 (`LICENSE`). Copies of the extensions that were released under MIT stay MIT; changes from now on are AGPL.
The `kind` in `package.toml` is the truth, and `pkg.py repo-check` refuses a folder whose kind does not belong in it.
Other files: `index.toml` (all packages, with their versions), `tests/` (all tests, `tests/run-all.sh`), `examples/`, `scripts/` and
`rust-toolchain.toml` (the build of Rust extensions).

## Use a package

```
hs pkg refresh
hs pkg fetch
hs pkg available
hs pkg install <name>
hs pkg update <name>
```

Update one package at a time. Read the diff `hs pkg update` shows: recipes and other package commands run as root on the server
(extension services run as an unprivileged user since core 0.13).

## Add a package

1. Work on a branch `feature/<topic>` started from `develop`; open the pull request against `develop`.
2. Create the folder of its kind (`recipes/<name>/`, ...) with a `package.toml` (`name` = folder, semver `version`, `kind`, `title`,
   `requires_core`) and its files and tests. Add it to `index.toml`. Do not pick a version bump by hand: label the pull request `bump: minor`
   (a feature) or `bump: major` (a person has to act); no label means patch.
3. Run the checks against a checkout of the core (CI does the same):
   ```
   # recipes are linked as packages/, every extension and capability folder into tree/capabilities/<name>
   mkdir -p tree/capabilities && ln -s "$PWD/recipes" tree/packages
   HS_PACKAGES_ROOT="$PWD/tree" python3 -I ../core/scripts/pkg.py validate
   python3 -I ../core/scripts/pkg.py repo-check .
   HS_CORE=../core bash tests/run-all.sh
   ```
4. Details per kind and the rules of the helpers: CONTRIBUTING.md and the core's docs (docs/PLAN-packages.md, docs/PLAN-registry.md).

## Releases and the signed index

There are no tags in this repository. Two branches:

- `develop` is where work lands (default branch, pull requests go here).
- `main` is what servers get. A release is a pull request `develop` into `main`, merged with a merge commit (no squash).

On every push to `main` (and daily, and by hand) the workflow `index` builds `index.json` and the resized assets, signs the index with the
index key (environment `index-signing`, usable from `main` only) and publishes both to GitHub Pages. The signature is verified against
`config/trusted-keys/official.allowed_signers` of the core before anything is published. A server reads the index, checks the signature and
installs the commit the index names. The serial of the index only goes up. The release preparation (workflow `prepare-release`, on `develop`)
raises the versions from the bump labels and opens the pull request; the Rust programs of extensions are built and committed in that pull request.

The signing workflow uses the core at a pinned commit SHA (`index.yml`): a core change reaches the signing job only through a reviewed pull request here that bumps the pin.

The signed index is published at https://packages.hobnix.dev/official/index.json. Seen on one real server: installing and updating packages from it. Not tested on hardware yet: applying a blueprint.

## Where this tree comes from

It was built by `scripts/dev/merge-package-repos.sh` of hobnix/core from the histories of hobnix/recipes, hobnix/extensions and
hobnix/capabilities, which stay in the history unchanged (commits made before the merge mostly carry no `Signed-off-by`). `capabilities/`
holds no package yet. `index.toml` is the list of all packages.

## More

Core and documentation: https://github.com/hobnix/core. Security reports: SECURITY.md. Contributing: CONTRIBUTING.md.

## AI was used here

Large parts of the code, the documentation and the tests of this project were written with the help of AI coding assistants. The maintainer
directs, reviews and tests the work, but not everything has been run on every kind of hardware, and AI-written code can be wrong in ways that
look right. Packages run as root on your server: read what you install, and report what you find.
