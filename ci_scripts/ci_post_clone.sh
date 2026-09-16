#!/bin/bash
set -euo pipefail

# Xcode Cloud runs this immediately after cloning the repository and before the
# build starts.
#
# The MobileVLCKit/TVVLCKit xcframeworks (~140 MB of prebuilt binaries) are
# intentionally NOT committed to git (see .gitignore). Fetch and stage the
# pinned, checksum-verified build so the Xcode build can link against them.
# install_vlckit.sh installs BOTH the iOS and tvOS frameworks, so a single run
# covers every platform and workflow.

ROOT_DIR="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

"${ROOT_DIR}/ci_scripts/install_vlckit.sh"

# Fail loudly and early if the frameworks did not end up in place — a clear
# message here beats a cryptic "There is no XCFramework found at ..." from the
# linker later in the build.
for framework in MobileVLCKit TVVLCKit; do
    if [ ! -d "${ROOT_DIR}/Frameworks/${framework}.xcframework" ]; then
        echo "error: ${framework}.xcframework is missing after install_vlckit.sh." >&2
        exit 1
    fi
done

echo "VLCKit frameworks staged; the build can now link MobileVLCKit and TVVLCKit."

# Xcode 26 and later ship the Metal compiler as a separate, downloadable
# component that the Xcode Cloud images do not include. Without it, compiling
# VideoEnhancementShaders.metal fails with "cannot execute tool 'metal' due to
# missing Metal Toolchain" (preceded by a red herring: a warning that the
# shader's .dia diagnostics file does not exist, because metal never ran).
#
# Downloading is a no-op once the component is present, and older Xcode versions
# have the toolchain built in and do not know the flag, so a failure here is only
# fatal if the toolchain is genuinely missing — which the build itself reports.
if xcodebuild -downloadComponent MetalToolchain; then
    echo "Metal toolchain available; VideoEnhancementShaders.metal can compile."
else
    echo "warning: could not download the Metal toolchain; continuing." >&2
fi
