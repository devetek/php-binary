# php-binary

Prebuilt PHP for Debian and Ubuntu servers, so a server downloads PHP instead
of compiling it for 10 minutes or more.

Every release is built in GitHub Actions by [mise](https://mise.jdx.dev) with
the dPanel PHP plugin, [dPanel-ID/mise-php](https://github.com/dPanel-ID/mise-php):
the same plugin compiles PHP when no prebuilt release fits a server, so a
download and a local build are the same PHP. The plugin uses these releases by
itself.

## What a release contains

One release per PHP version, tagged `php-X.Y.Z`, with one archive per OS
release and CPU:

```
php-8.4.27-ubuntu-24.04-arm64.tar.xz
php-8.4.27-ubuntu-24.04-arm64.tar.xz.sha256
```

| | |
| --- | --- |
| PHP branches | 8.1, 8.2, 8.3, 8.4, 8.5 (the newest patch release of each); 8.0, 7.4, 7.3 and 5.6 follow |
| OS releases | Ubuntu 22.04, 24.04, 26.04; Debian 12, 13 |
| CPUs | amd64, arm64 |
| Install path | `/usr/local/share/mise/installs/php/X.Y.Z`, where `mise install --system` puts tools, shared by every user of the server |
| SAPIs | CLI and PHP-FPM (with systemd notify) |
| Extensions | the plugin's default set (bcmath, curl, gd with AVIF/WebP, intl, mbstring, mysqli, pdo_mysql, pdo_pgsql, soap, sodium, zip, …), OPcache enabled, and the PECL extensions in [scripts/pecl-extensions.txt](scripts/pecl-extensions.txt): igbinary, apcu, redis, imagick, memcached |

Inside each archive:

- `runtime-packages.txt`: the OS packages PHP links to. A server installs
  these, and no compiler.
- `build-info.json`: PHP, OS, CPU, mise and plugin versions, and the PECL
  extension versions.
- `conf.d/`: one `.ini` per extension that is loaded.

## Use it

With mise and the dPanel plugin (recommended):

```bash
mise plugin install php https://github.com/dPanel-ID/mise-php
sudo mise install --system php@8.4
```

By hand:

```bash
v=8.4.27; asset="php-$v-ubuntu-24.04-$(dpkg --print-architecture).tar.xz"
curl -fLO "https://github.com/devetek/php-binary/releases/download/php-$v/$asset"
curl -fLO "https://github.com/devetek/php-binary/releases/download/php-$v/$asset.sha256"
sha256sum -c "$asset.sha256"
sudo mkdir -p /usr/local/share/mise/installs/php
sudo tar -C /usr/local/share/mise/installs/php -xJf "$asset"
xargs -a /usr/local/share/mise/installs/php/$v/runtime-packages.txt sudo apt-get install -y --no-install-recommends
/usr/local/share/mise/installs/php/$v/bin/php -v
```

PHP looks for `php.ini` and its extensions in the install path above. To use a
build somewhere else, set `PHPRC` and `PHP_INI_SCAN_DIR` to its directory and
`conf.d`, and `extension_dir` in a `conf.d` file; the plugin does this itself.

## How it is built

[.github/workflows/build.yml](.github/workflows/build.yml):

- **Daily** it reads the newest patch release of each branch from php.net and
  builds the ones without a release yet, so security releases arrive within a
  day.
- **By hand** (Run workflow) it builds the versions you type, or rebuilds
  existing ones.
- **On a pull request** it builds one version on Ubuntu 24.04 for both CPUs,
  without publishing.

Each build runs [scripts/build.sh](scripts/build.sh) in a container of its OS
release on a native amd64 or arm64 runner, then
[scripts/smoke-test.sh](scripts/smoke-test.sh) unpacks it on a clean container
of the same OS with only its runtime packages and checks PHP, PHP-FPM and every
extension. Only builds that pass are published.

The PHP source is downloaded from php.net and checked against its published
SHA-256.

## License

The build scripts are MIT licensed. PHP is distributed under the
[PHP License](https://www.php.net/license/); each archive includes PHP's
`LICENSE`.
