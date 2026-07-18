# Releasing Claudex

Claudex is open source under the MIT license.

The shared publication contract lives at `docs/public-release.md` in the separate
`mjukis.dev` repository.

## Local gates

```bash
swift test
swift build -c release
```

## Local/private package

```bash
./scripts/release.sh --allow-unnotarized
```

By default this produces a universal macOS app zip for Apple Silicon and Intel:
`dist/Claudex-X.Y.Z.zip`.

This development/ad-hoc path is for local testing or Homebrew source builds only.

## Notarized public build

The primary development machine is configured for team MJUKIS AB (`SMQ3E8Y57T`)
with `Developer ID Application: MJUKIS AB (SMQ3E8Y57T)` and the stored notarytool
profile `mjukis-notary`.

```bash
./scripts/release.sh --notarize --notary-profile mjukis-notary
```

That command builds the app and helper for Apple Silicon and Intel, signs nested
code inside-out with hardened runtime and a secure timestamp, submits the zip to
Apple, staples the accepted ticket, verifies the signatures, runs Gatekeeper, and
re-zips the stapled app.

On a new machine, first install the Developer ID certificate and store credentials:

```bash
xcrun notarytool store-credentials mjukis-notary \
  --apple-id "<apple-id>" \
  --team-id SMQ3E8Y57T \
  --password "<app-specific-password>"
```

## Tag, GitHub release, and Homebrew

For a public source/Homebrew release:

1. Set both bundle versions in `Resources/Info.plist`, move the changelog entries
   from **Unreleased** into the dated version section, commit, and push `main`.
2. Create and push an annotated `vX.Y.Z` tag on that exact commit.
3. Publish the notarized GitHub release asset and update mjukis.dev metadata.
   This defaults to the public notarization path and uses the matching changelog
   section as release notes:

   ```bash
   ./scripts/publish-github-release.sh
   ```

4. Compute the GitHub tag-tarball SHA-256, update `Formula/claudex.rb` and the
   matching formula in `everlof/homebrew-tap`, run `brew audit`/install tests,
   then commit and push both formula updates.

`--allow-unnotarized` remains available only for an explicitly documented private
beta. Never use it for the normal public release.
Use `--skip-website` only when the mjukis.dev metadata update should be handled
manually.

## Publish release metadata to mjukis.dev

The GitHub publish command above runs this automatically. After a GitHub release
exists and the download URL is public, the manual website-only command is:

```bash
./scripts/publish-website-release.sh
```

This updates the mjukis.dev worktree only. Remove any stale non-notarized warning,
review the website diff, run its build, commit, deploy, and verify the public page
and release download.
