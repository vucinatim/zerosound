# ZeroSound updates

ZeroSound uses Sparkle 2 for direct updates. Apple does not identify or notarize these builds, so a
person must approve the first installation with **System Settings → Privacy & Security → Open
Anyway**. Sparkle then owns update discovery, verification, atomic replacement, and relaunch.

## Trust boundary

- The appcast and archives are served over HTTPS.
- Every update ZIP is signed with Sparkle EdDSA using the keychain account
  `com.zerosound.updates`.
- The matching public key is embedded as `SUPublicEDKey` in `App/Info.plist`.
- The private key remains in the developer's login Keychain and must never enter the repository.
- GitHub hosting is not trusted to authorize code: an archive without the EdDSA signature is
  rejected.

Without Apple Developer ID, macOS may still apply Gatekeeper policy to an updated bundle. The exact
Open Anyway and update flow must be tested on a second Mac for every supported macOS generation.
Managed Macs may prohibit unidentified applications entirely.

## Validation status

On macOS 26, an ad-hoc 0.8 build installed in `/Applications` successfully fetched the local test
appcast, verified the EdDSA-signed 0.9 universal archive, atomically replaced itself, and relaunched
as 0.9. Both architectures and the final nested code signatures verified successfully. Address and
thread sanitizer runs also passed all 41 core tests.

This proves the updater mechanics and ZeroSound's cryptographic update authority. It does not make
the app Apple-trusted: `spctl` correctly rejects the resulting ad-hoc bundle. Before office rollout,
repeat the complete AirDrop, Open Anyway, and subsequent HTTPS update flow on a Mac that has never
trusted ZeroSound. Treat Developer ID and notarization as the path to dependable public distribution,
not as a requirement for continued internal development.

## Hosting contract

The intended free setup is:

- GitHub repository and immutable release ZIPs: `vucinatim/zerosound`
- GitHub Pages appcast: `https://vucinatim.github.io/zerosound/appcast.xml`

Do not distribute a Sparkle-enabled build until its release archive is available and the feed
returns the committed appcast over HTTPS.

## Preparing a release

1. Update `CFBundleShortVersionString` and monotonically increase `CFBundleVersion` in
   `App/Info.plist`.
2. Run all tests and build the universal archive:

   ```bash
   swift test
   ./Scripts/build-app.sh release
   ```

3. Prepare the signed appcast, optionally passing Markdown release notes:

   ```bash
   ./Scripts/prepare-update.sh docs/releases/VERSION.md
   ```

4. Create GitHub tag and release `v<version>`, then upload the generated universal ZIP and checksum.
5. Commit and publish `site/appcast.xml` only after the immutable release asset is available.
6. Verify the feed URL and test an older installed build updating to the new release.

`ZEROSOUND_RELEASE_BASE_URL` can override the default GitHub Release URL for a different HTTPS
artifact host. The app feed URL remains an application trust/configuration decision and must be
changed deliberately in `App/Info.plist`.

## Key recovery

The private EdDSA key is the only authority existing unidentified installations can use to trust a
new version. Export it with Sparkle's `generate_keys --account com.zerosound.updates -x <file>`, put
that file in an encrypted offline backup, and delete the plaintext export immediately. Losing both
the login-keychain item and its backup requires users to perform a fresh manual installation.
