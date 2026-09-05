# OpenAC age assets v1

Reproducible inputs:

- ethereum/zkID: `b395e09c225ff45b003f0087c28e2e208e22f944`
- witnesscalc_adapter: `e5a82bcb7d54a4694fc0662c51b01d99134e686c`
- Mopro: `0.3.5`
- iOS deployment target: `16.0`
- architectures: `arm64-apple-ios`, `arm64-apple-ios-simulator`
- SwiftPM XCFramework checksum: `9eb080736b4aa73211a8ba1bdc057955edda8d430a0ac9e088e5aa31c4ac76f4`

The release gate generated fresh circuit keys, signed a fixed ES256 SD-JWT,
created Prepare and Show proofs for a hidden birth date, reblinded both proofs,
and accepted the linked verifier statement. The final normal-stack run measured
19,203 ms for Prepare and 777 ms for Show on the build Mac. These numbers are a
release check, not the iPhone/iPad timing result.

| Asset | gzip bytes | gzip SHA-256 | installed bytes | installed SHA-256 |
|---|---:|---|---:|---|
| `jwt_2k.r1cs.gz` | 28,202,219 | `efb45ed790e81fb6e1e3947f3749ee6ee1b3f03c069fff0227bd7ccb94d974a6` | 374,342,852 | `d4f8b34dfd454234872a34f47ea486545cb4d989c41ed75f856268718251dc6a` |
| `show.r1cs.gz` | 590,365 | `20d785277560fa96309832926bd7efc927e3976c0385b3e2bcae455ad4ad8c7d` | 4,017,428 | `3809e70502fa90f2038760da5f1399a1e3eb17923e5af872edf3dfa0b7d37a9a` |
| `prepare_proving.key.gz` | 23,609,142 | `3b45f8b1c24e5e82fc2462ed819a73fab0167dcce303e15e272fc6f99e44a277` | 431,866,474 | `853657d2e701215a65c5d97ab3cf5640e9aa8379ac6d106b7c82dc9b9d078e79` |
| `prepare_verifying.key.gz` | 23,609,093 | `d84ef20b28f0dd26b836022fc023424592d476a80b54d9ab80d51e43f698ee6a` | 431,866,442 | `9b45cc7462a236b1056d21c19e1e4dfc2cf52fd20538d43fbe072d9ed106e9d6` |
| `show_proving.key.gz` | 575,666 | `fa34e2cefe8da70476843f0a7037e249c7b1cf13c5c26a3f09a268393de61223` | 4,862,778 | `809f24ca6ee003b684e2282b77f5a47279528edee7654a3801770a2ffca67831` |
| `show_verifying.key.gz` | 575,630 | `b6daa9cefd23d27ce80bd182ced987caa1a4eeb91083fc6ceafbeb1210dfbad0` | 4,862,746 | `f0c447a9757d182e8aa23083bc3dba5a9a22f3e0fcbb344724568cc3c83352d8` |

The app independently checks both the compressed transport and installed bytes.
The holder downloads both R1CS files and both key pairs; the verifier downloads
only the two public verifying keys. Downloads are not included in proof or
verification timing.
