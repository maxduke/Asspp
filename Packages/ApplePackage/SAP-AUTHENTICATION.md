# Signed Store authentication

The previous login path used `/auth/v1/native/fast/` without an action signature.
The current Store bag advertises the legacy MZFinance `authenticate` endpoint,
SAP version 200, a certificate URL, and a setup URL. Login now serializes each
attempt once, obtains a local SAP signature for each send, and sends those exact
bytes with `X-Apple-ActionSignature`. Pod redirects and transport retries preserve
the body and obtain a fresh signature, matching ipatool's request handling. Only
an explicit first-attempt `-5000` response generates the attempt 2 body.
Transient HTTP responses and selected timeout/connection-closure errors share a
three-request limit per endpoint. Retries preserve the signed body and incorporate
response cookies, use 10/20-second backoff unless `Retry-After` specifies a delay,
and stop if Apple requests more than 30 seconds. Credential failures and
cancellation do not trigger transport retries.
Bag and authentication HTTP requests have a 30-second total deadline, and
authentication retries open a fresh HTTP/1.1 connection. Only 301, 302, 307 and
308 redirects can replay a login POST; a 303 cannot.

Authentication endpoint and redirect validation happen before credentials are
sent. SAP setup URLs are constrained to the documented Apple endpoints. The
native bridge receives only the request bytes and validated signing configuration;
it never contacts a third-party signing service. The password saved in `Account`
does not include the one-time verification code. Verification-required errors keep
the existing `Strings.authRequiresVerificationCode` UI contract.

## Native implementations and provenance

- macOS: dynamically load CommerceKit and use `CKSigningSession`, whose system
  service owns the handshake. The interface and call sequence are documented by
  [ipatool-sapfix](https://github.com/maksimryabkin/ipatool-sapfix/blob/45b10ddd8a3a3f56ecefbe84582df75331f775cc/pkg/mescal/signer_darwin.m).
  [Pastel's September 29 signer](https://github.com/EEliberto/Pastel-macOS/blob/7087860ae53003bb3c11021b6f166a1632b8144b/Scripts/SAPSigner.m)
  independently uses the same interface in a project targeting physical Apple
  Silicon Macs on macOS 26+. This is source evidence, not an Asspp device test.
  ipatool's subsequent macOS 27 emulator asset migration does not establish
  whether CommerceKit remains usable on macOS 27; that requires device validation.
- Physical iOS: dynamically load StoreServices and create a dedicated
  `SSVFairPlaySAPSession` with `initWithURLBagDictionary:SAPVersion:`. Use its
  synchronous `signatureWithData:error:` on a background worker. These selectors
  are present in the [iOS 17 runtime header](https://github.com/MTACS/iOS-17-Runtime-Headers/blob/main/PrivateFrameworks/StoreServices.framework/SSVFairPlaySAPSession.h).
- The iOS adapter verifies the initialized URL bag interpreter resolves the
  exact validated setup/certificate URLs and SAP version before signing.
- All selectors are checked before invocation. Sessions are never shared across
  accounts. Native failures, absent APIs, exceptions and timeouts fail closed.
  A lock guards completion ownership, so late native results cannot resume a
  Swift continuation twice. The 30-second deadline bounds the caller's wait;
  it cannot forcibly terminate a blocked OS signing operation. At most two
  native operations may remain outstanding; further requests fail as busy. Its worker and
  session remain alive until that call returns.
- Native failures expose the signing stage, up to four allowlisted NSError
  domains with numeric codes, and the OS version. Error descriptions, URLs,
  userInfo, request bytes and account credentials never enter the UI or log.
- Linux and the iOS simulator cannot supply the native signer. Fixture tests use
  an internal injectable signer and HTTP sender; production has no unsigned or
  synthetic-signature fallback.

The macOS bridge follows the MIT-licensed ipatool-sapfix call sequence. Its
copyright notice is reproduced in `SAP-THIRD-PARTY-NOTICES.txt`.
The protocol behavior follows [majd/ipatool](https://github.com/majd/ipatool/tree/1b9ff28/pkg/appstore).
No opaque downloaded WASM, private function addresses, or emulator JIT entitlement
is required.

## Verification and remaining compatibility gate

Run `Packages/ApplePackage/Scripts/check-native-sap.sh` on Xcode-equipped macOS
for Objective-C syntax checks against macOS, iOS-device and simulator SDKs. CI
runs this before package tests.

Run `swift test --package-path Packages/ApplePackage` for signed request, redirect,
retry, bag parsing, verification code, cookie, and credential-boundary fixtures.
For a real local signing smoke test on a Mac:

```sh
APPLEPACKAGE_TEST_NATIVE_SAP=1 swift test --package-path Packages/ApplePackage --filter AuthenticationProtocolTests.testNativeSAPSigning
```

The opt-in test signs synthetic data and does not send account credentials.
Device testing must additionally build through `Asspp.xcworkspace`, sign in with
a test account on macOS and a physical iOS device, complete 2FA, and rotate that
account's token. Verify an existing second account remains usable.

**Runtime compatibility is not established by fixture tests or an app build.**
The iOS/macOS builds and Apple SDK syntax checks passed in GitHub Actions for
`7c091cb`; the opt-in native signing smoke test was skipped. A subsequent iPhone
test inside LiveContainer failed in the native `signatureWithData:error:` call,
after the runtime, session and URL bag checks succeeded. The original build
discarded the underlying error, so that report does not establish whether the
failure is a handshake, native API or hosting restriction. The diagnostic build
preserves safe error codes so the next device test can distinguish these cases.

These are private system APIs. Current OS versions may remove their selectors,
restrict their services, or require different device identity behavior. The iOS
header establishes the ABI, not successful signing from a sandboxed app. Real
sign-in on the target OS and hosting environment remains required before claiming
device compatibility. LiveContainer sign-in is not currently verified working.
