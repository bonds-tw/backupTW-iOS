# OpenAC age-predicate native binding

This directory is the reproducible source overlay for the field-level age proof
used by 有備而來. It is based on Ethereum Privacy and Scaling Explorations'
`ethereum/zkID` commit `b395e09c225ff45b003f0087c28e2e208e22f944` and Mopro 0.3.5.

The overlay deliberately exposes only one application profile:

- verify an ES256 SD-JWT issuer signature and its committed birth-date disclosure;
- bind the credential's `cnf.jwk` key to a fresh verifier nonce;
- prove that the hidden ISO or Taiwan ROC birth date is not later than the
  verifier-supplied cutoff;
- link the Prepare and Show proofs and compare all public inputs against values
  supplied independently by the verifier.

`predicate.rs` is copied into the upstream mobile crate. `zkid-mobile.patch`
adds its UniFFI exports and pinned dependencies, and runs each native prover on
a dedicated 64 MB stack; the upstream 2K secp256r1 witness calculator otherwise
crosses the default macOS/iOS thread stack guard. `witnesscalc-adapter.patch`
keeps the iOS 16 deployment floor consistent and prevents an Apple Silicon
build from silently compiling the unnecessary Intel simulator slice.

Run `./build-ios.sh /path/to/clean/zkID` after compiling the upstream Circom
`jwt_2k` and `show` circuits. The script refuses any upstream revision other
than the reviewed commit. The resulting XCFramework must be zipped and its
SwiftPM checksum and SHA-256 recorded before publication; runtime circuit/key
files are separately pinned by `AgePredicateCircuitAssets.swift`.

`age_assets.rs` is the release gate for those runtime files. It creates the
deterministic circuit keys and then signs a fixed ES256 SD-JWT, proves a hidden
birth-date predicate, reblinds both linked proofs, and checks the exact verifier
statement. A release whose vector fails is not publishable.

Do not treat the self-issued MyData derivative as a government assertion. The
same proof mechanics hide its birth date, but the verifier result must keep the
source label `selfIssued` visible.

Upstream licenses remain Apache-2.0/MIT as declared by zkID and Mopro.
