# Update metadata conformance

`scripts/test-zag-v2-vector-conformance.sh` runs the Python reference vector
(`scripts/zag-v2-test-vector.py`) against the app's verified update pipeline:
`ZagUpdateMetadataV2` verification and validation plus the Keychain rollback
store. It uses only the vector's public test keys and disposable Keychain
state, and makes no network requests.

```sh
bash scripts/test-zag-v2-vector-conformance.sh
# set PYTHON if the default python3 lacks the cryptography package
```

## Result categories

| Output | Meaning | Effect |
|---|---|---|
| `PASS` | A mandatory check passed. | none |
| `KNOWN GAP` | A documented discrepancy below is still present. | none, but reported on every run |
| `FAIL` | A regression, a new discrepancy, or a change to the known-gap inventory. | the suite fails |

Mandatory checks cover the reference and positive envelopes, every signed
negative case not listed below, the canonical JSON differential corpus,
sequence conflict, increase and replay, untrusted and wrong-key rotation,
channel binding, and the artifact digest binding.

A negative case that is accepted and not listed below fails the suite. A
known gap that starts being rejected also fails the suite, printing the case's
`ipaURL`, `minimumIOSVersion` and the rejection error as evidence. The fix
must then remove the case from the list in
`scripts/test-zag-v2-vector-conformance.swift` and from this document in the
same change, so the inventory stays exact.

## Known gaps

The app and the metadata signer (`scripts/zag-sign-metadata-v2.py`) check
only that `ipaURL` uses `https`, has host `github.com` and a path starting
with `/zagorskey/zag-store-releases/releases/download/`, and that
`minimumIOSVersion` is non-empty. The reference vector expects these signed
payloads to be rejected, but both currently accept them:

| Case | Accepted input |
|---|---|
| `credentialedIPAURL` | `ipaURL` with `user:password@` credentials |
| `unexpectedIPAPort` | `ipaURL` with an explicit port |
| `ipaURLWithQuery` | `ipaURL` with a query string |
| `ipaURLWithFragment` | `ipaURL` with a fragment |
| `ipaPathTraversal` | `ipaURL` path with `../` segments |
| `encodedDotDotTraversal` | `ipaURL` path with an encoded `../` segment |
| `encodedPathSeparator` | `ipaURL` path with an encoded `/` |
| `encodedBackslash` | `ipaURL` path with an encoded `\` |
| `emptyReleaseTag` | `ipaURL` with an empty release tag segment |
| `missingReleaseAsset` | `ipaURL` with a release tag but no asset name |
| `invalidMinimumIOS` | `minimumIOSVersion` that is not a dotted numeric version |

Severity is low. Each case needs a payload signed by a trusted update key,
and the downloaded IPA must still match the signed SHA-256. These are
defence-in-depth gaps, to be closed in the app and the signer together.
