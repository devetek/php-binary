#!/usr/bin/env bash
# Check a packaged build on a clean OS: install only its runtime packages,
# unpack it where mise expects it, and run PHP, PHP-FPM and the extensions.
#
# Usage: scripts/smoke-test.sh dist/php-<version>-<os>-<release>-<arch>.tar.xz
set -euo pipefail

ARCHIVE="${1:?usage: smoke-test.sh <archive>}"
INSTALL_ROOT="${INSTALL_ROOT:-/usr/local/share/mise/installs/php}"
export DEBIAN_FRONTEND=noninteractive

(cd "$(dirname "${ARCHIVE}")" && sha256sum -c "$(basename "${ARCHIVE}").sha256")
mkdir -p "${INSTALL_ROOT}"
tar -C "${INSTALL_ROOT}" -xJf "${ARCHIVE}"
VERSION="$(basename "${ARCHIVE}" | cut -d- -f2)"
PREFIX="${INSTALL_ROOT}/${VERSION}"

apt-get update -qq
xargs -a "${PREFIX}/runtime-packages.txt" apt-get install -y -qq --no-install-recommends >/dev/null

PHP="${PREFIX}/bin/php"
"${PHP}" -v
MAJOR="${VERSION%%.*}"
MINOR="$(echo "${VERSION}" | cut -d. -f2)"
modules="bcmath curl exif gd intl mbstring mysqli openssl pdo_mysql pdo_pgsql pdo_sqlite soap sockets xsl zip"
modules="${modules} igbinary apcu redis imagick memcached"
# sodium exists from PHP 7.2; PHP 5 builds keep mysql and mcrypt.
{ [ "${MAJOR}" -ge 8 ] || { [ "${MAJOR}" -eq 7 ] && [ "${MINOR}" -ge 2 ]; }; } && modules="${modules} sodium"
[ "${MAJOR}" -lt 7 ] && modules="${modules} mysql mcrypt"
missing=""
for module in ${modules} "Zend OPcache"; do
  "${PHP}" -m | grep -qx "${module}" || missing="${missing} ${module}"
done
if [ -n "${missing}" ]; then
  echo "missing modules:${missing}" >&2
  "${PHP}" -r '' 2>&1 | head -20 >&2
  exit 1
fi
"${PHP}" -r 'new Redis(); new Imagick(); new Memcached(); echo "classes ok\n";'
# The plugin links GD to the OS's libgd; AVIF depends on how the OS built it.
"${PHP}" -r '$gd = gd_info(); $jpeg = isset($gd["JPEG Support"]) ? $gd["JPEG Support"] : $gd["JPG Support"]; if (!$jpeg || !$gd["PNG Support"] || (PHP_MAJOR_VERSION >= 7 && empty($gd["WebP Support"]))) exit(1); echo "gd ok: jpeg png", empty($gd["WebP Support"]) ? "" : " webp", empty($gd["AVIF Support"]) ? "" : " avif", "\n";'
"${PHP}" -r 'echo extension_loaded("intl") && (new NumberFormatter("id_ID", NumberFormatter::CURRENCY))->formatCurrency(1500, "IDR") ? "intl ok\n" : exit(1);'
cp "${PREFIX}/php-fpm.conf.default" /tmp/php-fpm.conf
sed -i 's|^include=.*|;include|' /tmp/php-fpm.conf
printf '[www]\nuser = nobody\nlisten = /tmp/php-fpm.sock\npm = static\npm.max_children = 1\n' >> /tmp/php-fpm.conf
"${PREFIX}/sbin/php-fpm" -t -y /tmp/php-fpm.conf
echo "smoke test passed: $(basename "${ARCHIVE}")"
