# hobnix/official

The packages of the Hobnix server that its team maintains, in one repository: recipes (apps), extensions and capabilities. The `kind` in
each `package.toml` tells them apart, the folder says the same: `recipes/`, `extensions/`, `capabilities/`, `blueprints/`.

Servers read the signed `index.json` that is built from `main`; `develop` is where the work happens. A release is the merge of `develop` into
`main`, there are no tags.

Licence: AGPL-3.0 (`LICENSE`) for everything except `recipes/`, which is MIT (`recipes/LICENSE`). The extensions were MIT before this
repository existed: copies that were released stay MIT.

This tree was built by `scripts/dev/merge-package-repos.sh` of hobnix/core from the histories of hobnix/recipes, hobnix/extensions and
hobnix/capabilities, which stay in the history unchanged.
