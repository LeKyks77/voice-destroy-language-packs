# Voice Destroy — Language Packs

Dépôt officiel des packs de reconnaissance vocale téléchargeables pour **Voice Destroy**.

Les modèles Vosk ne sont jamais stockés dans l'historique Git. Les ZIP finaux sont publiés comme
fichiers d'une GitHub Release, puis référencés par le catalogue public [`manifest.json`](manifest.json).
Chaque client contrôle la taille exacte et le SHA-256 avant l'installation.

## Catalogue public

```text
https://raw.githubusercontent.com/LeKyks77/voice-destroy-language-packs/main/manifest.json
```

Ajouter uniquement un ZIP à GitHub ne le fait pas apparaître dans le jeu : il manque son identifiant,
sa variante, sa licence, sa taille et son SHA-256. En revanche, le constructeur du dépôt génère
automatiquement toutes ces entrées à partir des sources déclarées.

## Modèles disponibles

Chaque langue peut proposer plusieurs variantes dans le même accordéon du jeu :

| Variante | Usage | Ressources Vosk |
|---|---|---|
| `small` | Petits PC, réponse rapide, reconnaissance plus approximative | environ 50 Mo à télécharger et 300 Mo de RAM |
| `normal` | Meilleure précision, PC haut de gamme | 1 à 2 Go à télécharger et jusqu'à 16 Go de RAM |

Vosk recommande les petits modèles pour les applications de bureau. Les gros modèles visent plutôt
un processeur Intel i7 ou AMD Ryzen récent. Activer deux gros modèles simultanément exige beaucoup
de mémoire.

## Ajouter une langue ou une variante

1. Créer `sources/<langue>/pack.json` et `sources/<langue>/dictionary.json`.
2. Déclarer chaque variante Vosk dans `pack.json` (`small`, `normal`, ou une autre variante).
3. Ajouter le nom de l'archive, sa taille, son SHA-256 et son dossier racine dans
   `tools/model-sources.json`.
4. Placer les archives Vosk officielles dans `downloads/`.
5. Construire la publication :

   ```powershell
   .\tools\build-language-packs.ps1 -ReleaseTag packs-v1.1.0
   ```

6. Joindre tous les fichiers créés dans `dist/` à la GitHub Release correspondante.
7. Committer puis pousser le `manifest.json` généré. Le jeu affichera alors automatiquement la
   nouvelle langue et ses variantes au prochain rafraîchissement du catalogue.

Le script parcourt automatiquement tous les dossiers `sources/`; aucune liste de langues n'est
codée en dur.

## Structure

```text
manifest.json                 catalogue public consommé par le mod
schemas/                      formats JSON versionnés
sources/<langue>/pack.json    langue et variantes proposées
sources/<langue>/dictionary.json
tools/model-sources.json      empreintes des archives Vosk officielles
tools/build-language-packs.ps1
docs/PACK_FORMAT.md           contenu et règles de publication
```

Les modèles français et anglais utilisés actuellement sont distribués par Vosk sous licence
Apache-2.0. Leur licence et leurs crédits restent présents dans chaque archive publiée.
