# ApplePackage compatibility fork

This local Swift package is based on [Lakr233/ApplePackage 1.2.7](https://github.com/Lakr233/ApplePackage/tree/28710fec47fa89dfdedf2bf47cc284a2334ddfdc)
(MIT; see LICENSE). Keeping the patched library in this repository makes the app
build reproducibly without waiting for an upstream release. Its existing public
models and persisted account/download formats are retained. The unused CLI target
and its ArgumentParser dependency are omitted.

The protocol changes follow these [majd/ipatool](https://github.com/majd/ipatool)
updates:

- August 28, 2026: SAP-signed authentication (`abd86cb`). Asspp uses the native
  Apple signing engine with explicit certificate/setup exchanges on iOS,
  following ipatool's wire protocol. ipatool's CPU emulator and its jailbreak
  iOS CLI are not embedded in this app. See
  [SAP-AUTHENTICATION.md](SAP-AUTHENTICATION.md) for runtime requirements and limits.
- September 13: recover empty/unavailable volumeStore responses through the bag's
  redownload/update endpoints (`30b2909`), and allow packages without SINF (`dd28a3a`).
- September 18 / October 8: try consumer iPhone/iPad catalogs and the public iOS
  catalog when enterprise offers are absent (`e5211d6`, `e3932ce`).
- October 1: retain the exact signed authentication bytes through validated
  redirects (`1ec8b3e`), and retry transient HTTP responses, timeouts and dropped
  connections with a shared three-request limit and bounded backoff (`e258fed`).
- October 5 / 6: normalize the initial authentication path and route phone-number
  Apple Accounts to the appropriate storefront (`f9aa653`, `93b527a`).
- October 15: redownload owned delisted apps when the public catalog returns 404,
  and accept legacy iOS packages without platform declarations (`7578671`, `1b9ff28`).

The fallback chain retains the account session and explicit version throughout.
Only known availability failures trigger recovery. Authentication/license errors,
malformed catalog data, transport failures and rate limits are not converted into
an unrelated fallback. Recovered responses must match the requested app ID,
bundle ID and version. Dispatch URLs and credential-bearing redirects are validated.
Asspp also validates the top-level IPA platform before signature injection.
Authentication retries retain session cookies, including cookies received with
temporary errors. Cookies from different account pods, paths and download
dispatch hosts coexist rather than replacing each other by name.
The shared Store response parser accepts XML plists, binary plists and Apple's
Document/Protocol envelopes, including bare dictionary fields.

Run the offline regression suite with:

```sh
swift test --package-path Packages/ApplePackage
```

Linux builds use swift-crypto for MD5 and intentionally cannot authenticate using
Apple's system signing service. The offline suite does not require an Apple ID.
Build both app targets through `Asspp.xcworkspace` on a Mac, and verify sign-in,
2FA, free license acquisition, latest/historical downloads and IPA installation
on the target Apple devices before release.
The diagnostic build reached the native iOS session inside LiveContainer on
iOS 27.0.1 but returned `SSErrorDomain/122`. The new iOS adapter replaces that
session's internal networking with explicit certificate/setup requests and
retains a separate error stage for each handshake step. That environment still
requires device validation; self-signing alone is not a verified fix.

The October 1 ipatool `ent/download` / kbsync generator is not ported: it depends
on ipatool's emulated Apple runtime. This fork uses its supported legacy dispatch
recovery chain. It does not add macOS App Store `.pkg` download support; Asspp's
macOS target continues to manage iOS IPAs.
