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
MAJOR="${PHP_VERSION%%.*}"
MINOR="$(echo "${PHP_VERSION}" | cut -d. -f2)"
# PHP 8.0 and older need OpenSSL 1.x and old ICU: they are built on an old
# OS (Ubuntu 18.04, or 16.04 for 5.6) and carry those libraries with them,
# so one archive per CPU runs on every newer Debian and Ubuntu.
LEGACY=0
if [ "${MAJOR}" -lt 8 ] || { [ "${MAJOR}" -eq 8 ] && [ "${MINOR}" -eq 0 ]; }; then
  LEGACY=1
  NAME="php-${PHP_VERSION}-linux-${ARCH}"
else
  NAME="php-${PHP_VERSION}-${ID}-${VERSION_ID}-${ARCH}"
fi

log() { printf '\n==> %s\n' "$*"; }

log "Tools for ${ID} ${VERSION_ID} ${ARCH}"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
# The plugin installs PHP's own build dependencies. These are for mise and
# for the options and PECL extensions dPanel adds.
packages=(ca-certificates curl git xz-utils file python3
  libxslt1-dev libffi-dev libsystemd-dev libmagickwand-dev libmemcached-dev)
if [ "${LEGACY}" = 1 ]; then
  packages+=(patchelf)
  # bison 2.7 is compiled below, before the plugin installs its toolchain.
  [ "${MAJOR}" -lt 7 ] && packages+=(libmcrypt-dev build-essential m4)
  apt-cache show libargon2-0-dev >/dev/null 2>&1 && packages+=(libargon2-0-dev)
else
  packages+=(libavif-dev libargon2-dev)
fi
apt-get install -y -qq --no-install-recommends "${packages[@]}" >/dev/null

if [ "${MAJOR}" -lt 7 ]; then
  # PHP 5.6 regenerates its parsers with bison 2.x and looks for gmp.h in
  # /usr/include only.
  (cd /tmp && curl -fsSL https://ftp.gnu.org/gnu/bison/bison-2.7.1.tar.xz | tar -xJ &&
    cd bison-2.7.1 && ./configure --prefix=/usr/local >/dev/null && make -j"${JOBS}" >/dev/null && make install >/dev/null)
  ln -sf "/usr/include/$(dpkg-architecture -qDEB_HOST_MULTIARCH)/gmp.h" /usr/include/gmp.h
  export PATH="/usr/local/bin:${PATH}"
fi

curl -fsSL https://mise.run | MISE_VERSION="${MISE_VERSION}" MISE_INSTALL_PATH=/usr/local/bin/mise sh >/dev/null
mise --version
# Pin the plugin to one commit, recorded in build-info.json.
# From /tmp: the checkout belongs to another user, and git refuses to run
# inside it ("unsafe repository") on Ubuntu 18.04.
PLUGIN_COMMIT="$(cd /tmp && git ls-remote "${PLUGIN_URL}" "${PLUGIN_REF}" | cut -f1 | head -1)"
PLUGIN_COMMIT="${PLUGIN_COMMIT:-${PLUGIN_REF}}"
mise plugin uninstall php >/dev/null 2>&1 || true
mise plugin install php "${PLUGIN_URL}#${PLUGIN_COMMIT}"

log "Build PHP ${PHP_VERSION} with the plugin"
export MISE_EXPERIMENTAL=1
# Compile here: this build is what servers download.
export PHP_DPANEL_PREBUILT=0
extra="--with-fpm-systemd --with-fpm-user=www-data --with-fpm-group=www-data --with-xsl --with-pdo-sqlite --with-sqlite3"
[ "${LEGACY}" = 0 ] && extra+=" --with-avif"
# FFI exists from PHP 7.4, Argon2 passwords from 7.2.
{ [ "${MAJOR}" -ge 8 ] || { [ "${MAJOR}" -eq 7 ] && [ "${MINOR}" -ge 4 ]; }; } && extra+=" --with-ffi"
{ [ "${MAJOR}" -ge 8 ] || { [ "${MAJOR}" -eq 7 ] && [ "${MINOR}" -ge 2 ]; }; } && extra+=" --with-password-argon2"
# Legacy PHP 5 applications still call mysql_* and mcrypt_*.
[ "${MAJOR}" -lt 7 ] && extra+=" --with-mysql=mysqlnd --with-mcrypt"
export PHP_EXTRA_CONFIGURE_OPTIONS="${extra}"
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
  echo "zend_extension=opcache.so" > "${PREFIX}/conf.d/10-opcache.ini"
fi
: > "${WORK}/pecl-built.txt"
"${HERE}/pecl-select.py" "${HERE}/pecl-extensions.txt" "${PHP_VERSION}" | while read -r ext version; do
  cd "${WORK}"
  curl -fsSL -o "${ext}-${version}.tgz" "https://pecl.php.net/get/${ext}-${version}.tgz"
  rm -rf "${ext}-${version}"
  tar -xzf "${ext}-${version}.tgz"
  cd "${ext}-${version}"
  "${PREFIX}/bin/phpize" >/dev/null
  case "${ext}" in
    redis) pecl_flags="--enable-redis-igbinary" ;;
    memcached) pecl_flags="--enable-memcached-igbinary" ;;
    *) pecl_flags="" ;;
  esac
  # shellcheck disable=SC2086
  ./configure --with-php-config="${PREFIX}/bin/php-config" ${pecl_flags} >/dev/null
  make -j"${JOBS}" >/dev/null
  make install >/dev/null
  # igbinary first: redis and memcached load it.
  order=20; [ "${ext}" = igbinary ] && order=15
  # With ".so": PHP before 7.2 does not add it.
  echo "extension=${ext}.so" > "${PREFIX}/conf.d/${order}-${ext}.ini"
  echo "${ext} ${version}" >> "${WORK}/pecl-built.txt"
done

log "Keep what a server needs"
# The plugin builds in the install directory; drop the source tree's leftovers.
keep=" bin sbin lib include php var pear pear.conf conf.d php-fpm.conf.default php-fpm.d php.ini-production php.ini-development "
for entry in "${PREFIX}"/* "${PREFIX}"/.[!.]*; do
  [ -e "${entry}" ] || continue
  case "${keep}" in *" $(basename "${entry}") "*) ;; *) rm -rf "${entry}" ;; esac
done

# Strip before bundling: old binutils cannot strip files patchelf rewrote.
find "${PREFIX}" -type f \( -perm -u+x -o -name '*.so' \) -exec sh -c 'if file "$1" | grep -q ELF; then strip --strip-unneeded "$1"; fi' _ {} \;

if [ "${LEGACY}" = 1 ]; then
  log "Bundle libraries"
  python3 "${HERE}/bundle-libs.py" "${PREFIX}"
  : > "${PREFIX}/runtime-packages.txt"
else
  log "Runtime packages"
  # The OS packages that provide the shared libraries PHP and its extensions
  # link to. Servers install these, and no compiler.
  "${HERE}/runtime-packages.py" "${PREFIX}" > "${PREFIX}/runtime-packages.txt"
fi
tr '\n' ' ' < "${PREFIX}/runtime-packages.txt"; echo

python3 - "${PREFIX}/build-info.json" <<PY
import json, sys
pecl = dict(line.split() for line in open("${WORK}/pecl-built.txt"))
json.dump({
    "php": "${PHP_VERSION}", "os": "${ID}", "os_release": "${VERSION_ID}", "arch": "${ARCH}",
    "bundled_libraries": ${LEGACY} == 1,
    "prefix": "${PREFIX}", "mise": "${MISE_VERSION}",
    "plugin": "${PLUGIN_URL}#${PLUGIN_COMMIT}",
    "pecl": pecl,
}, open(sys.argv[1], "w"), indent=2)
PY

curl -fsSL -o "${PREFIX}/LICENSE" "https://raw.githubusercontent.com/php/php-src/php-${PHP_VERSION}/LICENSE"

log "Package"
tar -C "${INSTALL_ROOT}" -cJf "${DIST}/${NAME}.tar.xz" "${PHP_VERSION}"
(cd "${DIST}" && sha256sum "${NAME}.tar.xz" > "${NAME}.tar.xz.sha256")
ls -la "${DIST}/${NAME}.tar.xz"
"${PREFIX}/bin/php" -v | head -1
