#!/usr/bin/env bash
set -euo pipefail

#######################################
# One-time setup: build Arch Docker image, run container, post-configure.
# Not idempotent: remove existing container "arch" before re-running.
#######################################

CONTAINER_NAME="${CONTAINER_NAME:-arch}"
CONTAINER_IP="${CONTAINER_IP:-172.20.0.13}"
HOST_MOUNT="${HOST_MOUNT:-/var/www/arch/data}"
DOCKER_NET="${DOCKER_NET:-dockers}"
TKG_REPO="${TKG_REPO:-https://github.com/fiercebrake/tkg.git}"

usage() {
    cat <<EOF
$(basename "$0") - Build and configure Arch Linux Docker image for package builds

Usage:
  $(basename "$0") [-h|--help]

Options:
  -h, --help   Show this help.

Environment (optional):
  CONTAINER_NAME   Container name (default: arch)
  CONTAINER_IP     Container IP on Docker network (default: 192.168.75.13)
  HOST_MOUNT       Host path mounted at /mnt (default: /var/www/arch/data)
  DOCKER_NET       Docker network name (default: dockers)
  TKG_REPO         tkg repo URL (default: https://github.com/fiercebrake/tkg.git)

Run once to set up the environment. If container \"$CONTAINER_NAME\" already exists,
remove it first: docker rm -f $CONTAINER_NAME
EOF
}

get_image() {
    local build_dir
    build_dir=$(mktemp -d)
    trap 'sudo rm -rf "$build_dir"' EXIT

    git clone https://gitlab.archlinux.org/archlinux/archlinux-docker.git "$build_dir/archlinux-docker"

    sed -i 's|podman # or docker|docker # or podman|g' "$build_dir/archlinux-docker/Makefile"
    sed -i 's|CMD\ \["/usr/bin/bash"\]||g' "$build_dir/archlinux-docker/Dockerfile.template"
    sed -i 's|-f|--network=host -f|g' "$build_dir/archlinux-docker/Makefile"

    cat <<'DOCKER_EOF' >>"$build_dir/archlinux-docker/Dockerfile.template"
RUN pacman -Syu --noconfirm --needed ansible-core ansible-lint ansible python python-pip python-pipx python-passlib \
                                     vim vim-vital vim-tagbar vim-tabular vim-syntastic vim-supertab vim-spell-es \
                                     vim-spell-en vim-nerdtree vim-nerdcommenter vim-indent-object vim-gitgutter \
                                     vim-devicons vim-ansible mlocate bash-completion pkgfile rsync git wget \
                                     reflector less libsecret gzip tar zlib xz openssh openssl sudo bind inetutils \
                                     whois nginx curl nginx screen ccid zenity wireplumber udisks2 p7zip udftools sed \
                                     gnupg zip unzip fuse jq make pkg-config openbsd-netcat shfmt gsmartcontrol \
                                     shellcheck bats cpupower
ENTRYPOINT ["/usr/bin/nginx", "-g", "daemon off;"]
DOCKER_EOF

    (cd "$build_dir/archlinux-docker" && sudo make image-multilib-devel)
}

run_image() {
    sudo docker run -d --name "$CONTAINER_NAME" \
        --net "$DOCKER_NET" --ip "$CONTAINER_IP" \
        -v "$HOST_MOUNT:/mnt" \
        archlinux/archlinux:multilib-devel
}

post_conf() {
    # sudo docker exec -it "$CONTAINER_NAME" mv /usr/bin/vi /usr/bin/vi-bak
    sudo docker exec "$CONTAINER_NAME" ln -sf /usr/bin/vim /usr/bin/vi

    sudo docker exec "$CONTAINER_NAME" bash -c 'cat > /etc/sudoers.d/repo << EOF
repo  ALL=(ALL:ALL) ALL
repo  ALL=(ALL) NOPASSWD: ALL
EOF'

    sudo docker exec "$CONTAINER_NAME" bash -c "useradd --system -s /usr/bin/nologin repo && usermod -aG wheel repo"
    sudo docker exec "$CONTAINER_NAME" bash -c "mkdir -p /home/repo && chown repo:repo /home/repo && mkdir -p /srv/code/tekne && mkdir -p /var/local/repo-tekne"
    sudo docker exec "$CONTAINER_NAME" sed -i 's|/usr/share/nginx/html|/var/local/tekne-repo|g' /etc/nginx/nginx.conf
    # sudo docker exec "$CONTAINER_NAME" bash -c "git clone $TKG_REPO /mnt/tkg"
    sudo docker exec "$CONTAINER_NAME" bash -c "chown -R repo:repo /mnt/tkg/ && chown -R repo:repo /srv/code && chown -R repo:repo /var/local/repo-tekne"
    sudo docker exec "$CONTAINER_NAME" bash -c "sudo -u repo git clone https://github.com/tekne-ops/bash /srv/code/tekne/bash"
    sudo docker restart "$CONTAINER_NAME"
}

main() {
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        usage
        exit 0
    fi

    if sudo docker ps -a -q -f "name=^${CONTAINER_NAME}$" | grep -q .; then
        echo "Container '$CONTAINER_NAME' already exists. Remove it first: docker rm -f $CONTAINER_NAME" >&2
        exit 1
    fi
    # get_image
    # run_image
    post_conf
}

main "$@"
