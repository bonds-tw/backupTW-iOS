# OpenACAgeSwift

This local package keeps the generated Mopro Swift binding reviewable while its
large, reproducibly built XCFramework is fetched from the immutable
`openac-age-v1` GitHub release. SwiftPM verifies the archive checksum before it
exposes the C FFI module to the app.

The binary contains no proving key, credential or circuit policy file. Runtime
R1CS and key assets have their own compressed and installed SHA-256 pins in the
app's `AgePredicateCircuitAssetCatalog`.
