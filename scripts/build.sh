#!/usr/bin/env bash
# Build one PHP release with mise and the dPanel PHP plugin, on the OS this
# runs on (a Debian or Ubuntu container), and package it as
# dist/php-<version>-<os>-<release>-<arch>.tar.xz.
#
# Usage: scripts/build.sh <php version, e.g. 8.4.27>
#
# The plugin compiles PHP exactly as it would on a server, so a prebuilt
# release and a plugin build are the same PHP. `mise install --system` builds
# in its system directory, /usr/local/share/mise/installs/php/<version>, which
# PHP records as its own path (php.ini, extension_dir): servers unpack the
# archive in the same place.
set -euo pipefail

PHP_VERSION="${1:?usage: build.sh <php version>}"
MISE_VERSION="${MISE_VERSION:-v2026.11.6}"
PLUGIN_URL="${PLUGIN_URL:-https://github.com/dPanel-ID/mise-php}"
PLUGIN_REF="${PLUGIN_REF:-master}"
INSTALL_ROOT="/usr/local/share/mise/installs/php"
PREFIX="${INSTALL_ROOT}/${PHP_VERSION}"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-/tmp/php-build}"
DIST="${DIST:-$(pwd)/dist}"
JOBS="$(nproc)"

. /etc/os-release
ARCH="$(dpkg --print-architecture)"
NAME="php-${PHP_VERSION}-${ID}-${VERSION_ID}-${ARCH}"

log() { printf '\n==> %s\n' "$*"; }

log "Tools for ${ID} ${VERSION_ID} ${ARCH}"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
# The plugin installs PHP's own build dependencies. These are for mise and
# for the options and PECL extensions dPanel adds.
apt-get install -y -qq --no-install-recommends \
  ca-certificates curl git xz-utils file python3 \
  libavif-dev libxslt1-dev libffi-dev libargon2-dev libsystemd-dev \
  libmagickwand-dev libmemcached-dev >/dev/null

curl -fsSL https://mise.run | MISE_VERSION="${MISE_VERSION}" MISE_INSTALL_PATH=/usr/local/bin/mise sh >/dev/null
mise --version
# Pin the plugin to one commit, recorded in build-info.json.
PLUGIN_COMMIT="$(git ls-remote "${PLUGIN_URL}" "${PLUGIN_REF}" | cut -f1 | head -1)"
PLUGIN_COMMIT="${PLUGIN_COMMIT:-${PLUGIN_REF}}"
mise plugin uninstall php >/dev/null 2>&1 || true
mise plugin install php "${PLUGIN_URL}#${PLUGIN_COMMIT}"

log "Build PHP ${PHP_VERSION} with the plugin"
export MISE_EXPERIMENTAL=1
# Compile here: this build is what servers download.
export PHP_DPANEL_PREBUILT=0
export PHP_EXTRA_CONFIGURE_OPTIONS="--with-fpm-systemd --with-fpm-user=www-data --with-fpm-group=www-data --with-avif --with-xsl --with-ffi --with-password-argon2 --with-pdo-sqlite --with-sqlite3"
# SKIP_PHP_BUILD=1 reuses PHP already built in this container, to redo only
# the steps after it.
if [ "${SKIP_PHP_BUILD:-0}" != 1 ]; then
  rm -rf "${PREFIX}"
  mise install --system "php@${PHP_VERSION}"
fi
[ -x "${PREFIX}/bin/php" ] || { echo "mise did not install PHP in ${PREFIX}" >&2; exit 1; }

log "PECL extensions"
mkdir -p "${WORK}" "${DIST}" "${PREFIX}/conf.d"
EXT_DIR="$("${PREFIX}/bin/php-config" --extension-dir)"
# OPcache is built but not loaded; every production site wants it.
if [ -f "${EXT_DIR}/opcache.so" ]; then
  echo "zend_extension=opcache" > "${PREFIX}/conf.d/10-opcache.ini"
fi
: > "${WORK}/pecl-built.txt"
grep -Ev '^\s*(#|$)' "${HERE}/pecl-extensions.txt" | while read -r ext version; do
  cd "${WORK}"
  curl -fsSL -o "${ext}-${version}.tgz" "https://pecl.php.net/get/${ext}-${version}.tgz"
  rm -rf "${ext}-${version}"
  tar -xzf "${ext}-${version}.tgz"
  cd "${ext}-${version}"
  "${PREFIX}/bin/phpize" >/dev/null
  case "${ext}" in
    redis) extra=(--enable-redis-igbinary) ;;
    memcached) extra=(--enable-memcached-igbinary) ;;
    *) extra=() ;;
  esac
  ./configure --with-php-config="${PREFIX}/bin/php-config" "${extra[@]}" >/dev/null
  make -j"${JOBS}" >/dev/null
  make install >/dev/null
  # igbinary first: redis and memcached load it.
  order=20; [ "${ext}" = igbinary ] && order=15
  echo "extension=${ext}" > "${PREFIX}/conf.d/${order}-${ext}.ini"
  echo "${ext} ${version}" >> "${WORK}/pecl-built.txt"
done

log "Keep what a server needs"
# The plugin builds in the install directory; drop the source tree's leftovers.
keep=" bin sbin lib include php var pear pear.conf conf.d php-fpm.conf.default php-fpm.d php.ini-production php.ini-development "
for entry in "${PREFIX}"/* "${PREFIX}"/.[!.]*; do
  [ -e "${entry}" ] || continue
  case "${keep}" in *" $(basename "${entry}") "*) ;; *) rm -rf "${entry}" ;; esac
done

log "Runtime packages"
# The OS packages that provide the shared libraries PHP and its extensions
# link to. Servers install these, and no compiler.
"${HERE}/runtime-packages.py" "${PREFIX}" > "${PREFIX}/runtime-packages.txt"
tr '\n' ' ' < "${PREFIX}/runtime-packages.txt"; echo

python3 - "${PREFIX}/build-info.json" <<PY
import json, sys
pecl = dict(line.split() for line in open("${WORK}/pecl-built.txt"))
json.dump({
    "php": "${PHP_VERSION}", "os": "${ID}", "os_release": "${VERSION_ID}", "arch": "${ARCH}",
    "prefix": "${PREFIX}", "mise": "${MISE_VERSION}",
    "plugin": "${PLUGIN_URL}#${PLUGIN_COMMIT}",
    "pecl": pecl,
}, open(sys.argv[1], "w"), indent=2)
PY

curl -fsSL -o "${PREFIX}/LICENSE" "https://raw.githubusercontent.com/php/php-src/php-${PHP_VERSION}/LICENSE"

log "Package"
find "${PREFIX}" -type f \( -perm -u+x -o -name '*.so' \) -exec sh -c 'if file "$1" | grep -q ELF; then strip --strip-unneeded "$1"; fi' _ {} \;
tar -C "${INSTALL_ROOT}" -cJf "${DIST}/${NAME}.tar.xz" "${PHP_VERSION}"
(cd "${DIST}" && sha256sum "${NAME}.tar.xz" > "${NAME}.tar.xz.sha256")
ls -la "${DIST}/${NAME}.tar.xz"
"${PREFIX}/bin/php" -v | head -1
