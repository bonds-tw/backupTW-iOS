# ZK verifying-key manifest and release procedure

This document is the release gate for the public files that let Bonds check a
zero-knowledge proof offline. The signing broker is deliberately outside this
trust boundary: it cannot add, approve, replace or revoke a verifying key.

## Compiled manifest

Manifest ID: `ethereum/zkID:RSA-X.509-Cert-latest:2026-07-15`

Source owner: [`ethereum/zkID`](https://github.com/ethereum/zkID). The former
`privacy-ethereum/zkID` URL currently redirects to this repository. The source
release is `RSA-X.509-Cert-latest`, published by the repository's GitHub Actions
release job. Because `-latest` is a rolling tag, the tag name is provenance, not
an integrity control; the four hashes compiled into the app are the control.

| Installed file | Release gzip bytes | Release gzip SHA-256 | Installed bytes | Installed SHA-256 |
| --- | ---: | --- | ---: | --- |
| `keys/cert_chain_rs4096_verifying.key` | 41,321,957 | `ba5054a5044115de5f51dcf4330ecf844423bd9e12aa311ca3e3756e1202fc8e` | 693,663,362 | `498dc13211a4311900fcbf1df029be109880905d08c4ab271a2f795f4fa1da7c` |
| `keys/user_sig_rs2048_verifying.key` | 16,513,623 | `c4eabf366d7baf99306db72573d129f89aeef5a178d3368ffaef2d475ae81b7b` | 274,677,818 | `d85d0738827dcdfe13dc5fbf0ce8cddab5cbef3d55e6bf02c9c749190bdc3091` |

The gzip hashes and byte counts were rechecked against GitHub's release API on
2026-08-31. The installed hashes are over the exact files OpenACSwift opens, not
over their gzip containers.

## Three assets with different responsibilities

- A **proving key** is a large public circuit parameter used only to create a
  proof. The proof-creation flow downloads its pinned gzip. If it is already
  present, Bonds may derive the corresponding verifying key from its measured
  byte prefix and then checks the derived file against the installed hash above.
- A **verifying key** is a public circuit parameter used only to check a proof.
  A checker-only Release build downloads the two rows above directly, without a
  signer or broker session. It verifies gzip hash, exact expanded size and
  installed hash before an atomic rename. It rechecks exact size and installed
  hash before offering Bluetooth and immediately before verification.
- The **issuer certificate** is a 1.6 KB trust anchor bundled with the app. It is
  neither a proving key nor a verifying key and is never authorized or fetched
  by the signing broker. Its certificate identity, chain and bundled pin are
  checked by `IssuerCertificate` on the proof-creation path.

## Updating the manifest

1. Treat any change under the rolling tag as a new release, even if filenames
   are unchanged. Record the GitHub release asset IDs, upload timestamps, byte
   counts and API-reported SHA-256 values in the pull request.
2. Download all four RSA-4096/user-signature proving and verifying gzip assets
   into an isolated temporary directory. Independently calculate each gzip
   SHA-256; stream-decompress it; record exact installed size and SHA-256.
3. Recheck the documented prefix relationship before retaining local derivation:
   each verifying file must equal the matching proving file without its final 32
   bytes. A changed relationship removes derivation; it is not worked around.
4. Run OpenACSwift against a known valid proof and a deliberately altered proof
   with the candidate installed files. A valid proof must pass all three checks;
   the altered proof must be refused as a proof verdict, not as an I/O failure.
5. Change compressed hashes, installed hashes, byte counts and `manifestID` in
   one reviewed commit. No remote manifest, Worker variable or broker response
   may override these values at runtime.
6. Run the unit suite and the Release boundary build. On a physical Release/TestFlight
   device, install from empty state, interrupt and resume one download, alter a
   test-container copy, repair it, switch off the network and check a known proof.

## Fail-closed and rollback rules

- If the rolling tag is republished while an older app is in use, the compressed
  hash mismatch is a **stale manifest**. The app keeps any old complete installed
  key, refuses the new bytes and asks for an app update. Retrying or asking the
  broker must not authorize the replacement.
- A truncated, wrong-size, unreadable or same-size altered installed key is a
  repair state, never a rejected-proof verdict. Bluetooth is not offered until
  both installed hashes pass. A replacement stays in staging until every check
  succeeds, then atomically replaces the old file.
- Roll back by shipping/reselecting the previous reviewed app build or reverting
  the manifest commit. Never roll back with a Worker flag. Before accepting any
  manifest update, retain the previous reviewed TestFlight build and immutable
  release evidence; otherwise a fresh install cannot be guaranteed to recover
  the former files after a rolling upstream asset is deleted.
- Broker or network downtime cannot disable keys that already pass the compiled
  manifest. Offline proof verification has no broker call and no remote feature
  flag.
