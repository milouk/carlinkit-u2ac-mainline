# Lean static aa-proxy-rs for the U2AC (armv7 musl, no wasm/io-uring, vendored OpenSSL, size-optimised)
FROM rust:bookworm
RUN apt-get update && apt-get install -y --no-install-recommends python3-pip git pkg-config make perl && rm -rf /var/lib/apt/lists/* \
 && pip3 install --break-system-packages ziglang==0.13.0 && cargo install cargo-zigbuild --locked \
 && rustup target add armv7-unknown-linux-musleabihf
WORKDIR /src
