# Format d'un pack Voice Destroy

Une archive publiée doit avoir une racine unique et contenir :

```text
pack.json
dictionary.json
model/
  am/
  conf/
  graph/
  ivector/
LICENSES/
  VOSK_MODEL_LICENSE.txt
  THIRD_PARTY_NOTICES.md
```

## Règles de publication

1. Le modèle est téléchargé depuis l'URL `upstream_url` du descripteur source.
2. Son nom et sa licence sont vérifiés sur la page officielle Vosk.
3. Le dossier racine du modèle est renommé en `model` dans l'archive finale.
4. L'archive ZIP finale est placée dans une GitHub Release, jamais dans l'historique Git.
5. Sa taille exacte et son SHA-256 sont inscrits dans `manifest.json` seulement après téléversement.
6. Le client télécharge dans un fichier `.part`, vérifie la taille et le SHA-256, puis installe le pack
   par déplacement atomique.
7. Une archive invalide, trop volumineuse ou contenant un chemin sortant de sa racine est refusée.

Les packs installés restent utilisables hors ligne. Le catalogue distant sert uniquement à installer,
mettre à jour ou supprimer un pack.
