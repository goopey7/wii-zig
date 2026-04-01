FROM archlinux:latest

RUN pacman -Sy --noconfirm zig dolphin-emu mesa libglvnd libx11 libxrandr libxrender libxinerama openal mesa-utils fontconfig pulseaudio

COPY config/dolphin /root/.config/dolphin-emu/
COPY wii-dev/ /root/.cache/zig/p/N-V-__8AANflfhYAav9z4GwY349hgnf_gJ35dLQOCRH1nKhR/

WORKDIR /repo
