#!/usr/bin/env bash
# RbenOS - build script
# Distro Linux minima para jogos, com GRUB e suporte a apps Windows (Wine + DXVK)
# Requisitos minimos da imagem final: 1 GB RAM, 2 GB de disco.
#
# Correr num Debian/Ubuntu como root, com internet:
#   sudo apt install debootstrap parted dosfstools e2fsprogs
#   sudo ./build-rbenos.sh
#
# Resultado: rbenos.img  (grava num pen com: sudo dd if=rbenos.img of=/dev/sdX bs=4M status=progress)
set -euo pipefail

IMG=rbenos.img
SIZE=2G
SUITE=trixie
MNT=$(pwd)/rootfs
MIRROR=http://deb.debian.org/debian

[ "$(id -u)" -eq 0 ] || { echo "Corre como root (sudo)."; exit 1; }

cleanup() {
  set +e
  for d in dev/pts dev proc sys boot/efi; do umount "$MNT/$d" 2>/dev/null; done
  umount "$MNT" 2>/dev/null
  [ -n "${LOOP:-}" ] && losetup -d "$LOOP" 2>/dev/null
}
trap cleanup EXIT

echo "==> A criar imagem de $SIZE"
rm -f "$IMG"
truncate -s "$SIZE" "$IMG"
parted -s "$IMG" mklabel gpt \
  mkpart bios 1MiB 2MiB set 1 bios_grub on \
  mkpart esp fat32 2MiB 66MiB set 2 esp on \
  mkpart root ext4 66MiB 100%

LOOP=$(losetup -fP --show "$IMG")
mkfs.vfat -F32 "${LOOP}p2"
mkfs.ext4 -L rbenos -O ^has_journal -m 0 "${LOOP}p3"

mkdir -p "$MNT"
mount "${LOOP}p3" "$MNT"

echo "==> debootstrap (base minima)"
debootstrap --variant=minbase --arch=amd64 \
  --include=systemd-sysv,dbus,udev,locales,sudo,kmod \
  --components=main,contrib,non-free,non-free-firmware \
  "$SUITE" "$MNT" "$MIRROR"

mkdir -p "$MNT/boot/efi"
mount "${LOOP}p2" "$MNT/boot/efi"
mount --bind /dev "$MNT/dev"
mount --bind /dev/pts "$MNT/dev/pts"
mount -t proc proc "$MNT/proc"
mount -t sysfs sys "$MNT/sys"

ROOT_UUID=$(blkid -s UUID -o value "${LOOP}p3")
ESP_UUID=$(blkid -s UUID -o value "${LOOP}p2")

cat > "$MNT/etc/fstab" <<EOF
UUID=$ROOT_UUID / ext4 defaults,noatime 0 1
UUID=$ESP_UUID /boot/efi vfat umask=0077 0 2
tmpfs /tmp tmpfs defaults,nosuid,nodev,size=256M 0 0
EOF

echo "rbenos" > "$MNT/etc/hostname"
echo "127.0.0.1 localhost rbenos" > "$MNT/etc/hosts"

cat > "$MNT/etc/os-release" <<EOF
PRETTY_NAME="RbenOS 1.0"
NAME="RbenOS"
VERSION="1.0"
ID=rbenos
ID_LIKE=debian
EOF

# APT mais leve
cat > "$MNT/etc/apt/apt.conf.d/99rbenos" <<EOF
APT::Install-Recommends "false";
APT::Install-Suggests "false";
Acquire::Languages "none";
EOF

cat > "$MNT/etc/apt/sources.list" <<EOF
deb $MIRROR $SUITE main contrib non-free non-free-firmware
deb $MIRROR $SUITE-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security $SUITE-security main contrib non-free non-free-firmware
EOF

echo "==> A instalar pacotes no chroot"
cat > "$MNT/tmp/setup.sh" <<'CHROOT'
set -e
export DEBIAN_FRONTEND=noninteractive
dpkg --add-architecture i386   # para jogos Windows de 32 bits
apt-get update

# Kernel primeiro (antes do GRUB, para o hook do update-grub nao falhar)
apt-get install -y linux-image-amd64 initramfs-tools firmware-linux-free

# GRUB: so os pacotes -bin (grub-pc e grub-efi-amd64 conflitam entre si)
apt-get install -y grub-pc-bin grub-efi-amd64-bin grub2-common grub-common

apt-get install -y \
  xserver-xorg-core xinit x11-xserver-utils xserver-xorg-input-libinput \
  openbox xterm pcmanfm \
  libgl1-mesa-dri mesa-vulkan-drivers vulkan-tools \
  pipewire pipewire-pulse wireplumber \
  wine wine64 libwine dxvk winetricks cabextract \
  zram-tools systemd-timesyncd \
  network-manager

# 32-bit (Wine + Mesa) - necessario para muitos jogos antigos
apt-get install -y wine32:i386 libgl1-mesa-dri:i386 mesa-vulkan-drivers:i386 || true

# GRUB
sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=3/' /etc/default/grub
sed -i 's/^GRUB_DISTRIBUTOR=.*/GRUB_DISTRIBUTOR="RbenOS"/' /etc/default/grub
sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet"/' /etc/default/grub
echo 'GRUB_DISABLE_OS_PROBER=true' >> /etc/default/grub
echo 'GRUB_DISTRIBUTOR="RbenOS"' >> /etc/default/grub

# zram = swap comprimida em RAM (essencial com 1 GB)
cat > /etc/default/zramswap <<EOF
ALGO=zstd
PERCENT=60
EOF

# Utilizador
useradd -m -s /bin/bash -G sudo,audio,video,input,netdev jogador
echo "jogador:rbenos" | chpasswd
echo "root:rbenos" | chpasswd

# Autologin na consola + arranque automatico do X
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin jogador --noclear %I \$TERM
EOF

cat > /home/jogador/.profile <<'EOF'
[ -f ~/.bashrc ] && . ~/.bashrc
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
  exec startx
fi
EOF
echo "exec openbox-session" > /home/jogador/.xinitrc

# Prefixo Wine com DXVK (Direct3D -> Vulkan) criado no primeiro arranque
mkdir -p /home/jogador/.config/openbox
cat > /home/jogador/.config/openbox/autostart <<'EOF'
xsetroot -solid "#101820" &
if [ ! -d "$HOME/.wine" ]; then
  (WINEPREFIX="$HOME/.wine" wineboot -u && \
   WINEPREFIX="$HOME/.wine" setup_dxvk install 2>/dev/null || true) &
fi
EOF

# Menu simples: clicar com botao direito no ambiente de trabalho
mkdir -p /home/jogador/.config/openbox
cat > /home/jogador/.config/openbox/menu.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_menu xmlns="http://openbox.org/3.4/menu">
<menu id="root-menu" label="RbenOS">
  <item label="Terminal"><action name="Execute"><command>xterm</command></action></item>
  <item label="Ficheiros"><action name="Execute"><command>pcmanfm</command></action></item>
  <item label="Executar .exe (Wine)"><action name="Execute"><command>wine start /unix %f</command></action></item>
  <item label="Configurar Wine"><action name="Execute"><command>winecfg</command></action></item>
  <item label="Reiniciar"><action name="Execute"><command>systemctl reboot</command></action></item>
  <item label="Desligar"><action name="Execute"><command>systemctl poweroff</command></action></item>
</menu>
</openbox_menu>
EOF
chown -R jogador:jogador /home/jogador

# Associar .exe ao Wine
update-binfmts --enable wine 2>/dev/null || true

systemctl enable NetworkManager zramswap

# GRUB: BIOS (legacy) e UEFI (removivel, funciona em qualquer PC)
CHROOT

chroot "$MNT" /bin/bash /tmp/setup.sh

echo "==> A instalar GRUB"
chroot "$MNT" grub-install --target=i386-pc --recheck "$LOOP"
chroot "$MNT" grub-install --target=x86_64-efi --efi-directory=/boot/efi --removable --no-nvram
chroot "$MNT" update-grub
# Garantir que o grub.cfg usa UUID e nao /dev/loopX
sed -i "s#/dev/loop[0-9]*p3#UUID=$ROOT_UUID#g" "$MNT/boot/grub/grub.cfg"

echo "==> Limpeza para poupar espaco"
chroot "$MNT" apt-get clean
rm -rf "$MNT"/var/lib/apt/lists/* "$MNT"/usr/share/doc/* "$MNT"/usr/share/man/* \
       "$MNT"/usr/share/info/* "$MNT"/tmp/setup.sh
find "$MNT"/usr/share/locale -mindepth 1 -maxdepth 1 ! -name 'pt*' ! -name 'en*' -exec rm -rf {} +

echo
df -h "$MNT" | tail -1
echo "==> Pronto: $IMG"
echo "Testar:  qemu-system-x86_64 -m 1024 -enable-kvm -drive file=$IMG,format=raw"
echo "UEFI:    adiciona -bios /usr/share/ovmf/OVMF.fd"
echo "Login: jogador / rbenos  (muda a password!)"
