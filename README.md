# Voice Destroy — Language Packs

Dépôt officiel des packs de reconnaissance vocale téléchargeables pour **Voice Destroy**.

Les modèles Vosk ne sont pas stockés dans l'historique Git. Ils seront publiés comme fichiers de
GitHub Release après vérification de leur licence, de leur taille et de leur empreinte SHA-256.

## Catalogue public

Le mod consultera le fichier [`manifest.json`](manifest.json) :

```text
https://raw.githubusercontent.com/LeKyks77/voice-destroy-language-packs/main/manifest.json
```

Les entrées du catalogue sont produites par le constructeur à partir des archives Vosk officielles.
Chaque client vérifie la taille et le SHA-256 avant d'installer un pack.

## Structure

```text
manifest.json                 catalogue public consommé par le mod
schemas/                      formats JSON validés
sources/fr_fr/                métadonnées et dictionnaire français
sources/en_us/                métadonnées et dictionnaire anglais américain
docs/PACK_FORMAT.md           contenu attendu d'une archive téléchargeable
```

## Packs prévus

| Identifiant | Langue | Modèle Vosk initial | État |
|---|---|---|---|
| `fr_fr` | Français | `vosk-model-small-fr-0.22` | prêt à construire |
| `en_us` | English (US) | `vosk-model-small-en-us-0.15` | prêt à construire |

Les petits modèles français et anglais sont distribués par Vosk sous licence Apache-2.0. Leurs
licences et crédits devront rester présents dans chaque archive publiée.

## Construire une publication

Les archives source attendues et leurs empreintes de confiance sont déclarées dans
[`tools/model-sources.json`](tools/model-sources.json). Après les avoir placées dans `downloads/` :

```powershell
.\tools\build-language-packs.ps1
```

Les ZIP finaux sont créés dans `dist/`. Ils doivent être joints à la GitHub Release indiquée par le
catalogue ; ils ne doivent pas être ajoutés à Git.
