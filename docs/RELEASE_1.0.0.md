# Publication des packs 1.0.0

## Branche à fusionner

```text
feat/fr-en-language-packs
```

La branche contient le catalogue, les dictionnaires, les schémas, les licences et le constructeur.
Les modèles et les ZIP générés restent volontairement hors de l'historique Git.

## GitHub Release

- Tag : `packs-v1.0.0`
- Titre : `Voice Destroy language packs 1.0.0`
- État : publication normale, pas une préversion

Joindre exactement ces deux fichiers depuis le dossier local `dist/` :

| Fichier | Taille | SHA-256 |
|---|---:|---|
| `voice-destroy-language-fr_fr-1.0.0.zip` | 42 211 434 octets | `6C5BBA87D73F08782CAAB52AB39F38863CD723F09EC348085015A5133CAC3A24` |
| `voice-destroy-language-en_us-1.0.0.zip` | 41 189 875 octets | `58C7AA9FDCF80336335EE787DF878C333155ACF7C1824BD03D108CB9C82B2531` |

Ne pas renommer les fichiers : leurs URL exactes sont inscrites dans `manifest.json` et dans le catalogue
de secours du mod 1.4.0.

## Texte de publication

```markdown
First stable French and US English speech-recognition packs for Voice Destroy 1.4.0.

- Vosk small models from Alpha Cephei
- Curated Minecraft dictionaries with common player vocabulary
- Exact size and SHA-256 verification before installation
- Offline use after installation
- Apache License 2.0 model notices included in every archive
```

## Contrôle final

Après publication, les deux URL suivantes doivent télécharger les fichiers joints et non une page HTML :

```text
https://github.com/LeKyks77/voice-destroy-language-packs/releases/download/packs-v1.0.0/voice-destroy-language-fr_fr-1.0.0.zip
https://github.com/LeKyks77/voice-destroy-language-packs/releases/download/packs-v1.0.0/voice-destroy-language-en_us-1.0.0.zip
```
