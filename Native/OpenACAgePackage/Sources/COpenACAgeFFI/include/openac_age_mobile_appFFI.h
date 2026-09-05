#pragma once

// The static-library XCFramework carries this generated UniFFI header, but
// Xcode 26 does not register its nested module map for SwiftPM consumers.
// Re-exporting the header through a source target keeps one canonical set of
// declarations while making `import openac_age_mobile_appFFI` reliable.
#include <openac_age_mobile_app/openac_age_mobile_appFFI.h>
