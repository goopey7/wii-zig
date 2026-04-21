FROM ubuntu:24.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    cmake git ninja-build pkg-config \
    libevdev-dev libusb-1.0-0-dev \
    libsfml-dev libminiupnpc-dev \
    libmbedtls-dev libcurl4-openssl-dev \
    libhidapi-dev libsystemd-dev \
    libudev-dev \
    libbluetooth-dev libasound2-dev \
    libpulse-dev libgl1-mesa-dev \
    libgtk-3-dev libavcodec-dev \
    libavformat-dev libswscale-dev \
    g++ && rm -rf /var/lib/apt/lists/*

RUN git clone --recursive --branch 2512 https://github.com/dolphin-emu/dolphin.git /dolphin

WORKDIR /dolphin/build

RUN cmake .. \
    -DLINUX_LOCAL_DEV=true \
    -DENABLE_QT=OFF \
    -DENABLE_SDL=OFF \
    -DENABLE_NOGUI=ON \
    -DENABLE_EGL=OFF \
    -DENABLE_X11=OFF \
	-DENABLE_FBDEV=OFF \
    -GNinja && \
    ninja dolphin-emu-nogui

RUN apt-get update && apt-get install -y strace

COPY ~/.config/dolphin-emu/ /root/.config/dolphin-emu/

RUN apt-get update && apt-get install -y curl xz-utils && \
    curl -L https://ziglang.org/download/0.15.2/zig-x86_64-linux-0.15.2.tar.xz | \
    tar -xJ -C /usr/local && \
    ln -s /usr/local/zig-linux-x86_64-0.15.2/zig /usr/local/bin/zig

COPY wii-dev/ /root/.cache/zig/p/N-V-__8AANflfhYAav9z4GwY349hgnf_gJ35dLQOCRH1nKhR/

ENV PATH="/usr/local/zig-x86_64-linux-0.15.2:/dolphin/build/Binaries:$PATH"
WORKDIR /repo
