#!/usr/bin/env bash
# survey_client (apps-upstream/survey_client). The app has no package.json and no composer packages: js/ and css/ hold handwritten
# files that git tracks, so there is nothing to build. A recipe is needed only because the default recipe
# refuses an app with committed js/ or css/ and no build script. This one says they are sources.
set -euo pipefail
echo "ionos-build: $APP: js/ and css/ are sources, nothing to build"
