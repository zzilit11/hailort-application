#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly APP_DIR="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"

exec env \
    VCTX_EXPERIMENT_MODEL_PROFILE="vit" \
    VCTX_EXPERIMENT_DEFAULT_MODEL="/home/taespberry/WORKSPACE/models/vit_base.hef" \
    VCTX_EXPERIMENT_DEFAULT_IMAGE="/home/taespberry/WORKSPACE/images/_images_2.png" \
    bash "${APP_DIR}/scripts/lib/vctx_four_process_experiment.sh" "$@"
