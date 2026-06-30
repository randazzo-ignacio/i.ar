#!/usr/bin/env bash
SCRIPT_DIR="$(realpath "$(dirname "${BASH_SOURCE[0]}")")"
source "${SCRIPT_DIR}/metaconfig/header.sh"

build() {
    IMAGE_DIR="$1"
    IMAGE_NAME="iar-$(basename "${IMAGE_DIR}")"
    CONTAINERFILE="${SCRIPT_DIR}/${IMAGE_DIR}/Containerfile"

    info "Building ${IMAGE_NAME} from ${CONTAINERFILE}"
    podman build -t "${IMAGE_NAME}" -f "${CONTAINERFILE}" ${SCRIPT_DIR} && \
    	info "Build complete." || \
	error "Build failed."
}

for image in images/*; do
	build $image
done
