#!/usr/bin/env bash
set -e

build_dir=$1
dst_dir=$2
channel=$3
docker_version=$4
version_json=$5

data_img="${dst_dir}/data.ext4"
data_dir="${build_dir}/data"

APPARMOR_URL="https://raw.githubusercontent.com/PowerLabs-be/power-pilot-version/master/apparmor_${channel}.txt"

# Make image
rm -f "${data_img}"
truncate --size="1280M" "${data_img}"
mkfs.ext4 -L "hassos-data" -E lazy_itable_init=0,lazy_journal_init=0 "${data_img}"

# Mount / init file structs
mkdir -p "${data_dir}"
sudo mount -o loop,discard "${data_img}" "${data_dir}"

trap 'docker rm -f ${container} > /dev/null; sudo umount ${data_dir} || true' ERR EXIT

# Use official Docker in Docker images
# We use the same version as Buildroot is using to ensure best compatibility
container=$(docker run --privileged -e DOCKER_TLS_CERTDIR="" \
    -v "${data_dir}":/mnt/data \
    -v "${build_dir}":/build \
    -d "docker:${docker_version}-dind" --feature containerd-snapshotter --data-root /mnt/data/docker)

docker exec "${container}" sh /build/dind-import-containers.sh

# Capture image URLs before the heredoc so ${images} expands correctly in the outer shell.
# An unquoted heredoc (<<EOF) performs $-expansion at construction time, so variables must
# be set in the outer shell before the heredoc is built.
images=$(jq -c '.images // {}' "${version_json}")

sudo bash -ex <<EOF
# Indicator for docker-prepare.service to use the containerd snapshotter
touch "${data_dir}/.docker-use-containerd-snapshotter"

# Setup AppArmor
mkdir -p "${data_dir}/supervisor/apparmor"
curl -fsL -o "${data_dir}/supervisor/apparmor/power-pilot-supervisor" "${APPARMOR_URL}"

# Persist build-time updater channel and image URLs.
# \$channel and \$images are jq variables; backslash-escape prevents the outer shell from
# expanding them. In an unquoted heredoc (<<EOF) all $-expansions happen at construction
# time; single quotes offer no protection here, so the backslash is required.
jq -n --arg channel "${channel}" --argjson images "${images}" \
  '{"channel": \$channel, "image": \$images}' > "${data_dir}/supervisor/updater.json"
EOF
