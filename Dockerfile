FROM archlinux:latest
RUN pacman -Sy --noconfirm zig dolphin-emu
COPY config/ /root/.config/dolphin-emu/
