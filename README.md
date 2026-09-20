# xcpng-images

Images XCP-ng **remasterisées pour une installation sans intervention**
(answerfile), destinées au déploiement bare metal par BYOI (OVH). Artefacts
publics de [Cloud_Platform](https://github.com/JCrysto/Cloud_Platform).

## Ce que contient une image

L'ISO amont de XCP-ng, **inchangée** sauf une ligne dans trois fichiers de
démarrage : le paramètre `answerfile=<url> install` ajouté à l'entrée `install`.

- `/boot/isolinux/isolinux.cfg` — démarrage BIOS
- `/EFI/xenserver/grub.cfg` — copie dans l'arborescence ISO
- `efiboot.img:/EFI/xenserver/grub.cfg` — **la copie que l'UEFI lit vraiment**

Le troisième n'est pas dans la documentation : la partition EFI porte sa propre
copie de `grub.cfg`, et c'est elle que `BOOTX64.EFI` charge. Patcher les deux
premiers seulement ne change rien en UEFI — ce qu'un serveur OVH utilise.

Les autres entrées (`safe`, `shell`, `no-serial`) sont intactes : ce sont les
issues de secours à la console.

**Aucun secret dans l'image.** L'answerfile est servi par la plateforme, par
adresse IP, pendant la fenêtre d'installation. Aucun answerfile réel
n'est dans ce dépôt : `answerfile.example.xml` ne montre que le format. En essai, il est
servi hors dépôt ; en production, par la plateforme.

## Construire

Une seule dépendance : Docker.

```bash
docker build -t xcpng-remaster .
docker run --rm -v "$PWD:/work" xcpng-remaster bash /work/remaster.sh inspect
docker run --rm -v "$PWD:/work" -e ANSWERFILE_URL="https://…/answerfile.xml" \
  xcpng-remaster bash /work/remaster.sh all
```

`inspect` télécharge l'ISO amont, **vérifie son empreinte SHA-256** contre celle
publiée par XCP-ng, et montre les fichiers de démarrage sans rien modifier.
`all` patche, réécrit l'ISO en rejouant l'équipement de démarrage d'origine
(`xorriso -boot_image any replay`), puis vérifie que le MBR hybride, la GPT, le
catalogue El Torito et `BOOTX64.EFI` ont survécu. Il refuse de produire une
image dont un seul de ces points échoue.

## Provenance

Chaque Release porte l'empreinte de l'ISO produite. On vérifie l'amont, on
transforme, on publie **notre** empreinte : la somme de XCP-ng ne s'applique
plus à l'image remasterisée, et cette page le dit plutôt que de le laisser
croire.
