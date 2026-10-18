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
native bridge receives only the request bytes, binary hardware ID, Apple certificate
and a setup exchange callback; it never contacts a third-party signing service. The password saved in `Account`
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
- Physical iOS: resolve the five SAP entry points by exported name from
  AppleMediaServices or StoreServices: `cp2g1b9ro`, `Mib5yocT`, `Fc3vhtJDvr`,
  `IPaI1oem5iL`, and `jEHf8Xzsv8K`. There are no fixed image offsets, private
  ivar writes, hardware-identity hooks, or executable-memory requirements.
  Resolution fails before invocation if any entry point is absent.
- As in [ipatool's machine initialization](https://github.com/majd/ipatool/blob/1b9ff28eb467cb37f803f8e4b9f0ea20f0b09f4a/internal/sap/machine/machine.go),
  decode the login GUID into 1–20 bytes and place them in a zero-padded 24-byte
  hardware block. Capture that GUID for the whole authentication operation,
  rather than rereading mutable global configuration during retries.
  Check the native initializer's result and context pointer explicitly. This
  bypasses `SSVFairPlaySAPContext`'s implicit hardware-identity discovery.
- The portable C adapter owns initialization, exchange states and cleanup.
  Wire version 200 must produce state 1 with a nonempty setup request, then
  state 0 after Apple's reply. Final exchange output may be empty. Signing
  requires that completed state and receives the original login bytes.
  Returned buffers are bounded, copied and disposed with Apple's allocator;
  every initialized context has one teardown, including failed handshakes.
- The native-long ABI follows [sapsigner's interoperability header](https://github.com/t0rr3sp3dr0/sapsigner/blob/883ede5d935829f045417578778dcb1ad227bf57/impl/tbd/mescal.h).
  Output slots reserve full native widths, initialize their upper bytes and
  accept older 32-bit writes on supported little-endian systems. Returned
  status values retain their signed 32-bit error code.
  [iOS 26.1 context disassembly](https://github.com/EthanArbuckle/iPhone18-3_26.1_23B85_Restore/blob/90aa0cfe59d9682b4265e1354c8b19ec3c7823ab/System/Library/PrivateFrameworks/StoreServices.framework/StoreServices/SSVFairPlaySAPContext.mm)
  corroborates the five primitives and context lifetime. Historical
  [iOS 16.1 SDK exports](https://github.com/xybp888/iOS-SDKs/blob/ad607cb07fe4ad1c9b91cf970bd228c2a9253207/iPhoneOS16.1.sdk/System/Library/PrivateFrameworks/AppleMediaServices.framework/AppleMediaServices.tbd)
  list those names; iOS 26.1 SDK stubs do not. This is a runtime capability
  check, not an established iOS 27 invocation path.
- Setup HTTP follows [ipatool's protocol implementation](https://github.com/majd/ipatool/blob/1b9ff28eb467cb37f803f8e4b9f0ea20f0b09f4a/internal/sap/protocol.go):
  plist data fields, `application/x-plist`, and a 1 MiB response limit. Asspp uses
  its own HTTP client with redirects disabled and a 20-second request deadline,
  bypassing `SSVLoadURLOperation` and its Store service/network configuration.
  Setup requests contain no login body, account cookies or credentials.
- All required iOS exports and macOS selectors are checked before invocation. Sessions are never shared across
  accounts. Native failures, absent APIs, exceptions and timeouts fail closed.
  A lock guards completion ownership, so late native results cannot resume a
  Swift continuation twice. The 30-second deadline bounds the caller's wait;
  it cannot forcibly terminate a blocked OS signing operation. At most two
  native operations may remain outstanding; further requests fail as busy. Its worker and
  session remain alive until that call returns.
- Native failures expose the signing stage, up to four allowlisted NSError
  domains with numeric codes, and the OS version. Error descriptions, URLs,
  userInfo, request bytes and account credentials never enter the UI or log.
  `ApplePackage.SAP.Native` retains the primitive's numeric status;
  `ApplePackage.SAP.Core` identifies adapter state/argument failures.
  `ApplePackage.SAP.Symbols` is a missing-export bitmask: 1 init, 2 exchange,
  4 sign, 8 teardown, 16 dispose; 32 means neither framework loaded.
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
The portable C engine fixtures additionally check binary identity, hardware
padding, native status preservation, null-context rejection, exchange-state
ordering, original signing bytes, output bounds and one-time resource cleanup.
For a real local signing smoke test on a Mac:

```sh
APPLEPACKAGE_TEST_NATIVE_SAP=1 swift test --package-path Packages/ApplePackage --filter AuthenticationProtocolTests.testNativeSAPSigning
```

The opt-in test signs synthetic data and does not send account credentials.
Device testing must additionally build through `Asspp.xcworkspace`, sign in with
a test account on macOS and a physical iOS device, complete 2FA, and rotate that
account's token. Verify an existing second account remains usable.

**Runtime compatibility is not established by fixture tests or an app build.**
The initial and diagnostic builds passed iOS/macOS compilation and SDK syntax
checks in GitHub Actions; the opt-in native signing smoke test was skipped.
The diagnostic build `c87c65c` failed on iOS 27.0.1 inside LiveContainer with
`iOS.sign; ApplePackage.SAP/2 -> SSErrorDomain/122` from the old
`SSVFairPlaySAPSession.signatureWithData:error:` adapter. The published session
implementation maps failed context setup to that same generic error, so it does
not identify a LiveContainer restriction or a particular setup failure.
The explicit setup build `12d26f5` then fetched the certificate successfully but
failed with `iOS.exchange-request; ApplePackage.SAP/2 -> SSErrorDomain/122`.
In the available context implementation, that error at the first exchange is
returned when initialization left the native context null; initialization may
silently leave it null after hardware discovery or native init fails. No setup
POST had occurred at that stage. This narrows the failure to local initialization,
without establishing a LiveContainer-specific cause.
The new direct adapter replaces that implicit initialization with the app's
explicit GUID, as ipatool does, and checks the result immediately. Runtime export
availability and successful native signing on iOS 27.0.1 remain pending device
validation. A credential-free certificate probe returned HTTP 200 and a nonempty
certificate during development.

These are private system APIs. Current OS versions may remove their exports/selectors,
restrict their services, or require different device identity behavior. The iOS
header establishes the ABI, not successful signing from a sandboxed app. Real
sign-in on the target OS and hosting environment remains required before claiming
device compatibility. LiveContainer sign-in is not currently verified working.

ipatool's current signing engine runs pinned Apple framework assets under
Unicorn. Its [iOS build script](https://github.com/majd/ipatool/blob/1b9ff28eb467cb37f803f8e4b9f0ea20f0b09f4a/tools/build-ios.sh)
targets a jailbroken standalone executable, with a
[private no-container entitlement](https://github.com/majd/ipatool/blob/1b9ff28eb467cb37f803f8e4b9f0ea20f0b09f4a/resources/ios-entitlements.plist).
That is not proof its executable-memory requirements work in an ordinary
self-signed app or a particular LiveContainer configuration. Asspp follows its
HTTP and signing sequence while retaining the installed native iOS engine.
Directly self-signing the same IPA is a useful hosting comparison; it does not
automatically grant private Store services or emulator privileges.
