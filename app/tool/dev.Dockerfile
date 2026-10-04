# Flutter for building and testing the app's Linux version without a desktop: tool/flutter.sh runs
# it. No Android SDK yet.
FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git unzip xz-utils zip \
      clang cmake make ninja-build pkg-config libgtk-3-dev liblzma-dev libstdc++-14-dev \
      libmpv-dev libsecret-1-dev libjsoncpp-dev \
    && rm -rf /var/lib/apt/lists/*
# media_kit builds mimalloc with plain Makefiles, which look for cc and c++.
ENV CC=clang CXX=clang++
ARG FLUTTER_VERSION=3.47.6
ENV PATH=/opt/flutter/bin:$PATH
# All in one layer: a precache or chmod in a layer of its own would store the whole SDK twice.
RUN curl -fsSL "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz" \
      | tar -xJ -C /opt \
    && git config --system --add safe.directory '*' \
    && flutter config --no-analytics --enable-linux-desktop \
    && flutter precache --linux \
    && dart --disable-analytics \
    && chmod -R a+rwX /opt/flutter
