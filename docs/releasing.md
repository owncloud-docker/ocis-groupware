# Releasing

A release is a signed tag. `scripts/release` creates it, and pushing the tag
starts the Release workflow, which publishes everything else.

## Making a release

```sh
scripts/release --dry-run   # show the version and the release notes
scripts/release             # create and push the signed tag
```

The script needs [git-cliff](https://git-cliff.org), the GitHub CLI and a GPG or
SSH signing key that GitHub shows as verified. Run it on an up-to-date `main`
with a clean working tree and passing CI. It refuses to continue otherwise.

It reads the commits since the last tag. A `feat` raises the minor version, a
`fix`, `perf` or `revert` raises the patch version, and a breaking change
(`feat!`, or a `BREAKING CHANGE:` footer) raises the major version. `chore`,
`ci`, `docs`, `test`, `build`, `refactor` and `style` commits do not release
anything on their own, and the script stops if nothing else is pending.

To pick a version yourself, pass it, for example `scripts/release v1.0.0-rc.1`.
The script asks you to confirm when it differs from the suggestion, and asks
once more before it creates and pushes the tag. Versions look like `v1.2.3` or
`v1.2.3-rc.1`. A version with a suffix is published as a pre-release.

The release notes go into the tag message, so the notes you read in the dry run
are the ones that get published. [COMMIT_CONVENTION.md](../COMMIT_CONVENTION.md)
describes how commit titles end up in the notes.

## What the workflow publishes

The Release workflow (`.github/workflows/release.yml`) first checks that the
tag is an annotated tag whose signature GitHub verifies, and takes the notes
from its message. Lightweight and unverified tags are refused. Then it builds
the binaries and the GitHub release: [GoReleaser](https://goreleaser.com) builds
`ocis-groupware` for linux and darwin on amd64 and arm64, with the web app
embedded. It uploads one `.tar.gz` per platform, a `checksums.txt` with SHA-256
sums and an SPDX SBOM for each archive, and creates the GitHub release with the
notes. The settings are in `.goreleaser.yaml`.

To publish a release for a tag that already exists, run the workflow by hand
and give it the tag name.

## The container image

This repository does not publish the container image.
[owncloud-docker/ocis-groupware](https://github.com/owncloud-docker/ocis-groupware)
builds it from the same signed tag and publishes it to Docker Hub as
[`owncloud/ocis-groupware`](https://hub.docker.com/r/owncloud/ocis-groupware), for
linux/amd64 and linux/arm64. It checks for new tags every 6 hours, and a maintainer
there can start the build by hand. Only tags like `v1.2.3` are built: the release
gets the tags `1.2.3` and `1.2.3-YYYYMMDD`, and the highest release also gets
`latest`. Pre-release tags such as `v1.2.3-rc.1` get no image.

## Checking changes to the release setup

Nothing here needs a tag.

```sh
goreleaser check
goreleaser release --snapshot --clean --skip=publish   # builds in dist/
actionlint .github/workflows/release.yml
docker buildx build --platform linux/arm64 .
git cliff --unreleased --tag v0.0.0-test --strip header
scripts/release --dry-run
```

The snapshot build also needs [syft](https://github.com/anchore/syft) for the
SBOMs. Add `--skip=sbom` to leave them out.
