#!/bin/sh
set -eu

module_path="/modules/libredis-roaring.so"
failure_path="/modules/build.failed"

if test -s "${module_path}"; then
  echo "redis-roaring module is already available."
  exit 0
fi

rm -f "${failure_path}"
trap 'status=$?; if test "${status}" -ne 0; then printf "redis-roaring build failed with exit %s\n" "${status}" > "${failure_path}"; fi' EXIT

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  build-essential \
  ca-certificates \
  cmake \
  git
rm -rf /var/lib/apt/lists/*

git clone --depth 1 --branch "${REDIS_ROARING_VERSION}" \
  --recurse-submodules --shallow-submodules \
  https://github.com/aviggiano/redis-roaring.git /tmp/redis-roaring
cd /tmp/redis-roaring

# Upstream's configure.sh also builds a complete Redis server for its dist
# bundle. Hannote only needs the module, so generate CRoaring's amalgamated
# headers and build the dedicated CMake target.
(
  cd src
  ../deps/CRoaring/amalgamation.sh
)
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DDISABLE_TESTS=ON
cmake --build build --target redis-roaring --parallel 1

install -m 0755 build/libredis-roaring.so "${module_path}.tmp"
mv "${module_path}.tmp" "${module_path}"
trap - EXIT

echo "redis-roaring ${REDIS_ROARING_VERSION} module is ready."
