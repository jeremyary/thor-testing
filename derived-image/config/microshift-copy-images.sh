#!/bin/bash
# This project was developed with assistance from AI tools.
set -eux -o pipefail

IMAGE_STORAGE_DIR=/usr/lib/containers/storage
IMAGE_LIST_FILE="${IMAGE_STORAGE_DIR}/image-list.txt"

[ -f "${IMAGE_LIST_FILE}" ] || exit 0

while IFS="," read -r img sha; do
    if ! skopeo inspect "containers-storage:${img}" &>/dev/null; then
        skopeo copy --preserve-digests \
            "dir:${IMAGE_STORAGE_DIR}/${sha}" \
            "containers-storage:${img}"
    fi
done < "${IMAGE_LIST_FILE}"
