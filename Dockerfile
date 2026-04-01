FROM archlinux:latest

RUN pacman -Sy --noconfirm zig dolphin-emu

COPY config/ /root/.config/dolphin-emu/
COPY wii-dev/ /root/.cache/zig/p/N-V-__8AANflfhYAav9z4GwY349hgnf_gJ35dLQOCRH1nKhR/

WORKDIR /repo