#!/bin/sh
# mainline/aa-build/build.sh [aa-proxy-rs git ref, default v1.3.0: the patches are made for it]  -> mainline/aa-build/out/aa-proxy-rs (static armv7 musl)
set -eu
OPT=${OPT:-s}
D=$(cd "$(dirname "$0")" && pwd); REF=${1:-v1.3.0}
docker build -q -t u2ac-aa-build "$D" >/dev/null
mkdir -p "$D/out"
docker run --rm -v u2ac-aa-src:/src -v u2ac-aa-cargo:/usr/local/cargo/registry -v "$D/out:/out" -v "$D/patches:/patches:ro" u2ac-aa-build sh -c "
  set -e
  [ -d /src/aa-proxy-rs/.git ] || git clone -q https://github.com/aa-proxy/aa-proxy-rs /src/aa-proxy-rs
  # clean tree at REF: checkout -f resets tracked files, clean removes files a previous build's patches
  # added (target/ is ignored, so it stays)
  cd /src/aa-proxy-rs && git fetch -q --tags origin && git checkout -q -f $REF && git clean -qfd && git log -1 --format='%h %cd %s'
  sed -i 's|^openssl = { version = \"0.10\" }|openssl = { version = \"0.10\", features = [\"vendored\"] }|' Cargo.toml
  grep -q '^openssl = .*vendored' Cargo.toml
  for p in /patches/*.patch; do [ -f \"\$p\" ] || continue; git apply \"\$p\" || { echo \"PATCH FAILED: \${p##*/}\"; exit 1; }; echo \"applied \${p##*/}\"; done
  # U2AC: rustls on ring only (ring is already linked); drops the aws-lc-rs backend (~MBs of C crypto)
  [ \"\${RUSTLS_RING:-1}\" = 1 ] && sed -i 's|^rustls = { version = \"0.23\" }|rustls = { version = \"0.23\", default-features = false, features = [\"ring\", \"std\", \"tls12\", \"logging\"] }|' Cargo.toml
  grep '^rustls = ' Cargo.toml
  [ \"\${RUSTLS_RING:-1}\" = 1 ] && sed -i 's/rustls::crypto::{aws_lc_rs, CryptoProvider}/rustls::crypto::{ring as aws_lc_rs, CryptoProvider}/' src/ssl_rustls.rs && grep -n 'ring as aws_lc_rs' src/ssl_rustls.rs
  # zig's compiler-rt provides __atomic_*; the build asks for -latomic, so give it an empty archive
  mkdir -p /tmp/atomic && python3 -m ziglang ar rcs /tmp/atomic/libatomic.a
  export RUSTFLAGS=\"-L/tmp/atomic -C target-cpu=cortex-a7 ${RUSTFLAGS_EXTRA:-}\"
  export CFLAGS_armv7_unknown_linux_musleabihf=\"${CFLAGS_EXTRA:-}\"
  export CARGO_PROFILE_RELEASE_OPT_LEVEL=${OPT:-s} CARGO_PROFILE_RELEASE_LTO=true CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1
  cargo zigbuild --release --no-default-features --target armv7-unknown-linux-musleabihf 2>&1 | tail -15
  cp target/armv7-unknown-linux-musleabihf/release/aa-proxy-rs /out/aa-proxy-rs
  ls -l /out/aa-proxy-rs; file /out/aa-proxy-rs || true"
