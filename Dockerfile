# Conteneur jetable de remasterisation XCP-ng.
#
# Ne touche pas a l'image de la plateforme : si l'experience reussit, ce
# travail migrera dans un workflow GitHub Actions du depot d'artefacts ; si elle
# echoue, on supprime ce dossier et rien n'a change ailleurs.
#
#   xorriso   lit et reecrit l'ISO en preservant MBR hybride et catalogue El Torito
#   mtools    lit la partition EFI (FAT) sans la monter
#   fdisk     montre la table de partitions hybride de l'ISO
FROM debian:trixie-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      xorriso mtools fdisk curl ca-certificates file \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /work
