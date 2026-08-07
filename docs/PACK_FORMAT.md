# Format d'un pack Voice Destroy

Le catalogue version 2 regroupe les variantes par langue. Une archive installable correspond à une
seule paire `langue + variante`, par exemple `fr_fr/small` ou `fr_fr/normal`.

## Contenu d'une archive

```text
pack.json
dictionary.json
model/
  am/
  conf/
  graph/
  ivector/                 facultatif selon le modèle
  rescore/                 facultatif selon le modèle
LICENSES/
  VOSK_MODEL_LICENSE.txt
  THIRD_PARTY_NOTICES.md
```

Le `pack.json` installé contient obligatoirement `id`, `variant`, `version`, `engine` et le modèle
d'origine. Le dictionnaire reste commun aux variantes d'une même langue.

## Règles de publication

1. Utiliser une archive provenant de l'URL officielle déclarée dans le descripteur source.
2. Enregistrer sa taille et son SHA-256 dans `tools/model-sources.json`.
3. Ne jamais committer les modèles ou ZIP dans Git.
4. Construire les packs avec `tools/build-language-packs.ps1`.
5. Publier les ZIP de `dist/` dans la GitHub Release dont le tag a été fourni au constructeur.
6. Pousser le `manifest.json` généré seulement après la publication des fichiers.
7. Conserver les licences et crédits dans chaque variante.

Le client télécharge dans un fichier `.part`, contrôle l'URL HTTPS, la taille et le SHA-256, vérifie
les chemins du ZIP et installe le modèle par déplacement atomique. Installer une autre variante de
la même langue remplace l'ancienne afin d'éviter de gaspiller plusieurs gigaoctets.

## Découverte dans le jeu

GitHub n'est pas parcouru comme un dossier. Le jeu lit exclusivement `manifest.json`. Le constructeur
rend néanmoins l'ajout simple : tout dossier valide placé sous `sources/`, accompagné de ses modèles
déclarés, devient automatiquement une langue et un accordéon dans le catalogue généré.
