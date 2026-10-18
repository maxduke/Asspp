# Signed Store authentication

The Store bag now selects MZFinance `authenticate`, SAP version 200, and the
certificate/setup endpoints. Each actual login send signs the exact serialized
POST bytes and includes `X-Apple-ActionSignature`, following
[majd/ipatool](https://github.com/majd/ipatool/tree/1b9ff28eb467cb37f803f8e4b9f0ea20f0b09f4a).
Redirects and transport retries preserve those bytes; only an explicit initial
`-5000` response advances the login attempt. Transient responses and selected
connection failures share a three-request limit with bounded backoff. Structured
credential failures and cancellation do not trigger transport retries. Cookies
remain account-specific, including cookies from temporary error responses.

Authentication endpoints and redirects are validated before credentials are
sent. SAP setup is restricted to `https://fpinit.itunes.apple.com/v1/signSapSetup/legacy`
and `https://s.mzstatic.com/sap/setupCert.plist`, with redirects disabled. Setup
requests contain certificate-exchange buffers, never login bodies or account
cookies. A request's GUID is captured once, decoded as 1–20 hardware bytes and
kept stable across signing, redirects and retries. Saved passwords exclude 2FA.

## iOS implementation

`Packages/SAPRuntime` contains the source-built ipatool SAP engine. Its pinned
Apple ARM64 components run inside Unicorn's TCI interpreter with executable
translation memory and Darwin JIT helpers disabled. Purego callbacks are
precompiled assembly trampolines. No private iOS SAP symbols, fixed system image
offsets, device identity interposition, jailbreak entitlement or signing server
is used. See its [README](../SAPRuntime/README.md) for source pins and build steps.

The initial download reads byte ranges of Apple's pinned macOS restore image,
extracts approximately 125 MB, verifies sizes and SHA-256 hashes, and writes an
atomic cache inside the actual app container. Swift obtains this path from
Foundation rather than the process-wide HOME, which can refer to LiveContainer.
Apple's binaries are downloaded on the device and are not redistributed in the
IPA. Cold preparation displays a localized message and supports cancellation.

The C archive exposes cancellable operation IDs, explicit-length byte buffers,
progress phases and numeric failure metadata. Its fixed-signature `uc_ctl` shim
is needed by Apple's ARM64 variadic ABI. Unicorn functions are statically
referenced rather than resolved through RTLD_DEFAULT; hidden library globals
avoid collisions when LiveContainer locally loads a guest image.

Only one interpreter signs at a time, with a separate context for each request.
The Go context bounds cold preparation to 15 minutes; guest invocations have a
one-minute CPU timeout. Cancellation resumes Swift exactly once and cancels
network work; an active guest invocation cleans up within its CPU timeout.
Buffers are copied before crossing ownership boundaries, login input copies are
cleared, and signer cleanup runs before releasing the interpreter slot. At most
two native C workers may remain outstanding. Released guest and asset memory is
returned promptly after each call.

## macOS implementation

macOS continues to load CommerceKit's `CKSigningSession` and check its selectors
before use. This follows the MIT-licensed
[ipatool-sapfix implementation](https://github.com/maksimryabkin/ipatool-sapfix/blob/45b10ddd8a3a3f56ecefbe84582df75331f775cc/pkg/mescal/signer_darwin.m).
The system owns that handshake. A 30-second caller deadline and a lock prevent
late callbacks from resuming a continuation twice; blocked system calls remain
bounded to two workers. The iOS emulator is not linked into the macOS app.
Current macOS runtime compatibility still requires a device test.

## Diagnostics and validation

Errors contain an allowlisted phase, up to four allowlisted NSError domains with
numeric codes, and the OS version. Descriptions, URLs, userInfo and signed data
never enter UI diagnostics. iOS phases now start with `iOS.runtime.`. A recognized
HTTP or guest status is retained as `ApplePackage.SAP.Runtime/<number>`; otherwise
the detail is zero. Cancellation is surfaced as `CancellationError`.

Run the offline protocol suite:

```sh
swift test --package-path Packages/ApplePackage
```

On a Mac, `Scripts/check-native-sap.sh` checks the Objective-C bridge against
macOS, device iOS and simulator SDKs. The iOS CI job additionally builds the
statically linked interpreter, runs its source/concurrency/C ABI tests, and
performs live Apple setup with two synthetic binary payloads before building the
IPA. None of these tests needs an Apple Account. The simulator build supports
ARM64; device account verification remains necessary.

Previous device results on iOS 27.0.1 inside LiveContainer:

- `c87c65c`: `iOS.sign; SSErrorDomain/122` from the session wrapper.
- `12d26f5`: `iOS.exchange-request; SSErrorDomain/122`, consistent with a null
  native context left by implicit initialization.
- `6d0657e`: `iOS.engine-load; ApplePackage.SAP.Symbols/31`, meaning all five
  required raw exports were absent. This establishes that the direct native
  adapter cannot work in that runtime; it does not establish a LiveContainer
  restriction that self-signing would resolve.

Those iOS paths have been removed. During development, both upstream Unicorn
and the source-built TCI interpreter completed real Apple setup and produced
distinct signatures for two test payloads. The warm TCI probe took about 2.3
seconds. This verifies the protocol and interpreter, not account login on a
physical iPhone. Validate adding an account, 2FA and token rotation inside
LiveContainer, then check a second account and a download before release.

ipatool source is MIT licensed. The new interpreter includes GPL-2.0 code; the
app bundles the notices and CI publishes the corresponding source beside the
IPA. See `Packages/SAPRuntime/Licenses` and its README. There is no unsigned or
synthetic-signature production fallback.
