# Voice Destroy — Language Packs

Dépôt officiel des packs de reconnaissance vocale téléchargeables pour **Voice Destroy**.

Les modèles Vosk ne sont pas stockés dans l'historique Git. Ils seront publiés comme fichiers de
GitHub Release après vérification de leur licence, de leur taille et de leur empreinte SHA-256.

## Catalogue public

Le mod consultera le fichier [`manifest.json`](manifest.json) :

```text
https://raw.githubusercontent.com/LeKyks77/voice-destroy-language-packs/main/manifest.json
```

Le catalogue reste volontairement vide tant que les premières archives `fr_fr` et `en_us` ne sont
pas construites et téléversées. Un client Voice Destroy ne doit jamais recevoir un lien ou une
empreinte provisoire.

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
| `fr_fr` | Français | `vosk-model-small-fr-0.22` | préparation |
| `en_us` | English (US) | `vosk-model-small-en-us-0.15` | préparation |

Les petits modèles français et anglais sont distribués par Vosk sous licence Apache-2.0. Leurs
licences et crédits devront rester présents dans chaque archive publiée.
