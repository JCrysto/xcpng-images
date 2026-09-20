#!/usr/bin/env bash
# Remasterisation XCP-ng pour installation sans intervention (answerfile).
#
# Phases :
#   inspect   telecharge l'ISO amont, verifie son empreinte, et MONTRE ce qu'elle
#             contient. Aucune modification.
#   patch     injecte `answerfile=<url> install` dans les TROIS fichiers de
#             demarrage. Trois, et non deux comme la documentation le laisse
#             croire : l'inspection a montre que la partition EFI porte sa propre
#             copie de grub.cfg, et c'est elle que BOOTX64.EFI lit. OVH demarre
#             en UEFI ; patcher la copie de l'ISO seule n'aurait rien change.
#   build     reecrit l'ISO en rejouant l'equipement de demarrage d'origine, puis
#             verifie que l'hybride (MBR + GPT + El Torito + ESP) a survecu.
#
# Variables : ANSWERFILE_URL (patch/build), obligatoire.
set -euo pipefail

WORK=/work
ISO_URL="https://mirrors.xcp-ng.org/isos/8.3/xcp-ng-8.3.0-20260806.iso?https=1"
ISO="$WORK/xcp-ng-8.3.0-20260806.iso"
OUT="$WORK/xcp-ng-8.3.0-20260806-answerfile.iso"
# L'empreinte enregistree dans la plateforme (image BYOI #1), elle-meme
# verifiee contre le fichier de sommes publie par XCP-ng.
EXPECTED_SHA256="1d06e2d88a0fbf9a38384aa46637fd5d1ad568ba0df7ab3ed95fb047655f22e6"
LAYOUT="$WORK/layout"
PATCHED="$WORK/patched"
CHECK="$WORK/check"

titre() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
echec() { printf '\033[31m!! %s\033[0m\n' "$*" >&2; exit 1; }

# xorriso commente abondamment sur stderr (NOTE, UPDATE). On garde les erreurs,
# on tait le bavardage, sans perdre le code de sortie.
xo() { xorriso "$@" 2> >(grep -vE '^xorriso : (NOTE|UPDATE)' >&2 || true); }
# Les rapports xorriso repetent un en-tete de six lignes ; on ne garde que l'utile.
rapport() { xo "$@" 2>/dev/null | grep -vE '^(xorriso [0-9]|Drive current|Media current|Media status|Boot record|Media summary|Volume id|Copying of file|$)'; }

# ---------------------------------------------------------------------------
phase_inspect() {
  titre "1. ISO amont"
  if [ -f "$ISO" ]; then echo "deja presente : $ISO"; else
    echo "telechargement de $ISO_URL"; curl -fsSL --retry 3 --retry-delay 5 -o "$ISO" "$ISO_URL"; fi
  ls -l --block-size=M "$ISO"

  titre "2. Empreinte (doit egaler celle de la plateforme)"
  echo "$EXPECTED_SHA256  $ISO" | sha256sum -c -

  titre "3. Table de partitions hybride"; fdisk -l "$ISO" || true
  titre "4. Catalogue El Torito";         rapport -indev "$ISO" -report_el_torito plain
  titre "5. Equipement de demarrage, en options mkisofs (rejoue tel quel au build)"
  rapport -indev "$ISO" -report_el_torito as_mkisofs
  rapport -indev "$ISO" -report_system_area as_mkisofs

  titre "6. Extraction des configurations vers $LAYOUT"
  rm -rf "$LAYOUT"; mkdir -p "$LAYOUT"
  xo -osirrox on -indev "$ISO" -extract /EFI "$LAYOUT/EFI" \
     -extract_single /boot/isolinux/isolinux.cfg "$LAYOUT/isolinux.cfg" \
     -extract_single /boot/efiboot.img "$LAYOUT/efiboot.img" >/dev/null
  mtype -i "$LAYOUT/efiboot.img" ::/EFI/xenserver/grub.cfg > "$LAYOUT/esp-grub.cfg"
  find "$LAYOUT" -type f | sort

  titre "7. La partition EFI"
  mdir -i "$LAYOUT/efiboot.img" -/ :: | grep -vE '^\s*$'
  titre "8. Difference entre les deux grub.cfg (ISO vs partition EFI)"
  diff -u "$LAYOUT/EFI/xenserver/grub.cfg" "$LAYOUT/esp-grub.cfg" || true

  titre "Inspection terminee — rien n'a ete modifie"
}

# ---------------------------------------------------------------------------
# Une seule ligne par fichier, dans le seul bloc « install » : les autres
# entrees (safe, shell, no-serial) restent intactes, ce sont nos issues de
# secours a la console. Chaque awk exige exactement une modification.
patch_isolinux() {  # $1 in, $2 out, $3 extra
  awk -v extra="$3" '
    /^LABEL /                     { inblock = ($2 == "install") }
    inblock && /^[ \t]*APPEND /   {
      n = split($0, p, " --- ")            # p[n-1] = "/boot/vmlinuz console=…", p[n] = "/install.img"
      p[n-1] = p[n-1] " " extra
      line = p[1]; for (i = 2; i <= n; i++) line = line " --- " p[i]
      $0 = line; changed++
    }
    { print }
    END { if (changed != 1) { print "isolinux.cfg : " changed+0 " modification(s), attendu 1" > "/dev/stderr"; exit 1 } }
  ' "$1" > "$2"
}

patch_grub() {  # $1 in, $2 out, $3 extra
  awk -v extra="$3" '
    /^menuentry "install" \{/                     { inblock = 1 }
    inblock && /^[ \t]*module2 \/boot\/vmlinuz /   { $0 = $0 " " extra; changed++ }
    inblock && /^\}/                              { inblock = 0 }
    { print }
    END { if (changed != 1) { print FILENAME " : " changed+0 " modification(s), attendu 1" > "/dev/stderr"; exit 1 } }
  ' "$1" > "$2"
}

phase_patch() {
  : "${ANSWERFILE_URL:?ANSWERFILE_URL requis, ex. https://…/answerfile.xml}"
  [ -f "$LAYOUT/efiboot.img" ] || echec "lance 'inspect' d'abord"
  EXTRA="answerfile=$ANSWERFILE_URL install"

  titre "1. Patch des trois fichiers de demarrage"
  rm -rf "$PATCHED"; mkdir -p "$PATCHED/EFI/xenserver"
  patch_isolinux "$LAYOUT/isolinux.cfg"           "$PATCHED/isolinux.cfg" "$EXTRA"
  patch_grub     "$LAYOUT/EFI/xenserver/grub.cfg" "$PATCHED/EFI/xenserver/grub.cfg" "$EXTRA"
  patch_grub     "$LAYOUT/esp-grub.cfg"           "$PATCHED/esp-grub.cfg" "$EXTRA"

  titre "2. Ce qui change, exactement"
  diff -u "$LAYOUT/isolinux.cfg"           "$PATCHED/isolinux.cfg"           || true
  diff -u "$LAYOUT/EFI/xenserver/grub.cfg" "$PATCHED/EFI/xenserver/grub.cfg" || true
  diff -u "$LAYOUT/esp-grub.cfg"           "$PATCHED/esp-grub.cfg"           || true

  titre "3. Reecriture de grub.cfg DANS la partition EFI (mtools, sans montage)"
  cp "$LAYOUT/efiboot.img" "$PATCHED/efiboot.img"; chmod u+w "$PATCHED/efiboot.img"
  mcopy -o -i "$PATCHED/efiboot.img" "$PATCHED/esp-grub.cfg" ::/EFI/xenserver/grub.cfg
  n=$(mtype -i "$PATCHED/efiboot.img" ::/EFI/xenserver/grub.cfg | grep -c 'answerfile=' || true)
  [ "$n" = 1 ] || echec "la partition EFI ne porte pas l'answerfile (trouve $n)"
  # La taille de l'image FAT ne doit pas bouger : elle est aussi la partition 2 de l'hybride.
  [ "$(stat -c %s "$LAYOUT/efiboot.img")" = "$(stat -c %s "$PATCHED/efiboot.img")" ] || echec "taille de efiboot.img modifiee"
  echo "partition EFI patchee, taille inchangee : $(stat -c %s "$PATCHED/efiboot.img") octets"
  titre "Patch termine (fichiers dans $PATCHED, ISO intacte)"
}

# ---------------------------------------------------------------------------
phase_build() {
  [ -f "$PATCHED/efiboot.img" ] || echec "lance 'patch' d'abord"
  rm -f "$OUT"

  titre "1. Reecriture de l'ISO, equipement de demarrage rejoue depuis l'original"
  # `-boot_image any replay` : xorriso reprend El Torito, MBR hybride et GPT tels
  # qu'enregistres dans l'ISO chargee. Les trois -map remplacent les fichiers.
  xo -indev "$ISO" -outdev "$OUT" \
     -boot_image any replay \
     -map "$PATCHED/isolinux.cfg"           /boot/isolinux/isolinux.cfg \
     -map "$PATCHED/EFI/xenserver/grub.cfg" /EFI/xenserver/grub.cfg \
     -map "$PATCHED/efiboot.img"            /boot/efiboot.img \
     -commit >/dev/null
  ls -l --block-size=M "$OUT"

  titre "2. Verification : l'hybride a-t-il survecu ?"
  rm -rf "$CHECK"; mkdir -p "$CHECK"
  echo "--- partitions (original / remasterisee) ---"
  fdisk -l "$ISO" | grep -E '^/work' | sed 's#/work/[^ ]*iso##' > "$CHECK/fdisk.orig"
  fdisk -l "$OUT" | grep -E '^/work' | sed 's#/work/[^ ]*iso##' > "$CHECK/fdisk.new"
  paste -d '\n' "$CHECK/fdisk.orig" "$CHECK/fdisk.new"
  grep -qE '[[:space:]]ef[[:space:]]+EFI' "$CHECK/fdisk.new" || echec "plus de partition EFI dans l'hybride"

  echo "--- El Torito (remasterisee) ---"
  rapport -indev "$OUT" -report_el_torito plain | tee "$CHECK/eltorito.new"
  grep -q 'BIOS  y' "$CHECK/eltorito.new" || echec "entree BIOS perdue"
  grep -q 'UEFI  y' "$CHECK/eltorito.new" || echec "entree UEFI perdue"
  grep -q '/boot/efiboot.img' "$CHECK/eltorito.new" || echec "l'entree UEFI ne pointe plus sur efiboot.img"
  grep -q 'isohybrid-suitable' "$CHECK/eltorito.new" || echec "isolinux.bin plus isohybrid"

  echo "--- equipement mkisofs : original vs remasterisee (seule la date et le chemin peuvent differer) ---"
  rapport -indev "$ISO" -report_system_area as_mkisofs | grep -vE 'modification-date|interval:local_fs' > "$CHECK/sa.orig"
  rapport -indev "$OUT" -report_system_area as_mkisofs | grep -vE 'modification-date|interval:local_fs' > "$CHECK/sa.new"
  diff -u "$CHECK/sa.orig" "$CHECK/sa.new" && echo "identique"

  titre "3. Verification : les trois fichiers portent l'answerfile, BOOTX64.EFI est intact"
  xo -osirrox on -indev "$OUT" \
     -extract_single /boot/isolinux/isolinux.cfg "$CHECK/isolinux.cfg" \
     -extract_single /EFI/xenserver/grub.cfg     "$CHECK/grub.cfg" \
     -extract_single /boot/efiboot.img           "$CHECK/efiboot.img" >/dev/null
  for f in "$CHECK/isolinux.cfg" "$CHECK/grub.cfg"; do
    n=$(grep -c 'answerfile=' "$f" || true); [ "$n" = 1 ] || echec "$f : $n occurrence(s), attendu 1"; echo "ok  ${f#$CHECK/} (1 occurrence)"
  done
  n=$(mtype -i "$CHECK/efiboot.img" ::/EFI/xenserver/grub.cfg | grep -c 'answerfile=' || true)
  [ "$n" = 1 ] || echec "ESP:grub.cfg : $n occurrence(s), attendu 1"; echo "ok  ESP:/EFI/xenserver/grub.cfg (1 occurrence)"
  mtype -i "$LAYOUT/efiboot.img" ::/EFI/BOOT/BOOTX64.EFI | sha256sum | cut -d' ' -f1 > "$CHECK/bootx64.orig"
  mtype -i "$CHECK/efiboot.img"  ::/EFI/BOOT/BOOTX64.EFI | sha256sum | cut -d' ' -f1 > "$CHECK/bootx64.new"
  cmp -s "$CHECK/bootx64.orig" "$CHECK/bootx64.new" || echec "BOOTX64.EFI a change"
  echo "ok  BOOTX64.EFI identique ($(cut -c1-16 "$CHECK/bootx64.new")…)"
  echo "--- la ligne gravee, telle que grub la lira ---"
  mtype -i "$CHECK/efiboot.img" ::/EFI/xenserver/grub.cfg | grep 'answerfile='

  titre "4. Empreinte de l'ISO remasterisee (a publier avec elle)"
  sha256sum "$OUT" | tee "$OUT.sha256"
  titre "Build termine"
}

case "${1:-inspect}" in
  inspect) phase_inspect ;;
  patch)   phase_patch ;;
  build)   phase_build ;;
  all)     phase_patch; phase_build ;;
  *) echo "usage: $0 {inspect|patch|build|all}" >&2; exit 2 ;;
esac
