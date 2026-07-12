# quota-pilot

**Planification de tâches consciente du quota pour Claude Code.** Les tâches longues ne s'écrasent plus contre le mur du rate limit de 5 heures : avant l'épuisement de la fenêtre, la session évalue le travail restant, écrit un checkpoint, se règle un réveil à horloge murale, attend au repos à coût token nul et reprend automatiquement après le reset.

[English](README.md) | [中文](README-zh.md) | [Deutsch](README-de.md) | [Русский](README-ru.md)

## Pourquoi proactif ?

Les outils existants (claude-auto-retry et consorts) sont **réactifs** : ils laissent la session mourir sur le rate limit, puis tapent aveuglément « continue » via tmux. Triple échec — la coupure tombe généralement au milieu d'un turn (édition faite, tests jamais lancés), donc le modèle repris se trompe sur ce qui est réellement terminé ; il faut injecter des frappes tmux dans une session morte ; et aucune anticipation du budget restant.

quota-pilot inverse la logique : **la session ne meurt jamais**. Elle est alertée *avant* l'épuisement, juge elle-même si la prochaine unité de travail indivisible tient encore, archive honnêtement (y compris ce qui est à moitié fait et non vérifié), et se réveille toute seule. Pas de tmux, pas de launchd, pas de baby-sitter externe — uniquement des primitives natives de Claude Code.

## Fonctionnement

```
┌─ échantillonnage ─────────┐   ┌─ décision ───────────┐   ┌─ comportement (modèle) ──┐
│ primaire : poll oauth/    │   │ hook PostToolUse     │   │ skill quota-pilot        │
│ usage (throttlé dans le   │ → │ lit state.json       │ → │ 1. évaluer l'unité       │
│ hook, TOUTES les sessions)│   │ seuil + cooldown     │   │ 2. écrire le checkpoint  │
│ aux : wrapper statusline  │   │ injecte l'alerte     │   │ 3. réveil horloge murale │
│ (affichage TUI seulement) │   └──────────────────────┘   │ 4. repos → réveil → suite│
└───────────────────────────┘                              └──────────────────────────┘
```

- **warn** (88 % par défaut) : le modèle évalue si la prochaine unité indivisible tient dans le budget restant (réserve de 3 % pour le checkpoint). Si oui, il continue ; sinon, il archive et se gare.
- **critical** (95 % par défaut) : évaluation sautée, archivage immédiat.
- Le checkpoint (`<projet>/.claude/quota-checkpoint.md`) sépare *terminé-et-vérifié* de *en-cours-non-vérifié* — c'est cette distinction qui élimine les bugs de reprise aveugle.
- Le réveil est une boucle à horloge murale, pas un long `sleep` unique : l'horloge monotone de macOS s'arrête pendant la veille système, donc un `sleep 4h` sur un portable fermé dort des heures de trop. La boucle détecte une échéance dépassée dans les 60 s suivant le réveil de la machine.

## Installation

**Option A — script d'installation :**

```bash
git clone https://github.com/easyfan/quota-pilot.git
cd quota-pilot
./install.sh                # hook + skill + commande /quota
./install.sh --statusline   # installe aussi l'affichage TUI du quota
```

`--statusline` préserve une statusLine existante : votre commande d'origine continue de s'afficher à travers le wrapper pendant que les données de quota sont capturées en parallèle.

**Option B — marketplace de plugins :**

```
/plugin marketplace add easyfan/quota-pilot
/plugin install quota-pilot@quota-pilot
```

Désinstallation : `./install.sh --uninstall` (restaure la statusLine et les settings d'origine ; conserve l'état `~/.claude/quota-pilot/`, à supprimer manuellement si non désiré).

## Utilisation

Rien à faire — le hook surveille le quota à chaque appel d'outil (au plus une requête HTTPS par 60 s après throttling). Quand une alerte se déclenche, vous verrez le modèle évaluer, archiver et se garer de lui-même.

- `/quota` — utilisation 5h/7j courante, compte à rebours du reset, burn rate, projection d'épuisement
- `touch ~/.claude/quota-pilot/cancel` — réveiller une session garée en avance
- Le checkpoint vit dans `<projet>/.claude/quota-checkpoint.md` ; si le processus meurt pendant le stationnement, une session neuve peut reprendre depuis ce fichier

## Configuration (`~/.claude/quota-pilot/config.json`)

| Clé | Défaut | Signification |
|-----|--------|---------------|
| `warn_threshold` | 88 | seuil d'alerte d'évaluation (fenêtre 5h %) |
| `critical_threshold` | 95 | seuil d'archivage immédiat |
| `reserve` | 3 | budget réservé au checkpoint (%) |
| `cooldown_minutes` | 10 | cooldown de ré-alerte par niveau |
| `max_wait_hours` | 6 | au-delà, notifier l'humain au lieu d'attendre |
| `wake_jitter_minutes` | 5 | jitter aléatoire de réveil (garde anti-ruée multi-sessions) |
| `seven_day_warn` | 90 | seuil de notification fenêtre 7 jours (notification seule) |

## Limites

- **Comptes abonnement (Pro/Max) uniquement.** Les comptes à clé API n'ont pas de fenêtres de quota ; le plugin le détecte et reste dormant — zéro surcoût, zéro bruit.
- L'échantillonneur primaire utilise l'endpoint non documenté `oauth/usage` ; chaque réponse est validée par schéma et tout écart retombe en silence, jamais en fausse alerte.
- Le quota est au niveau du compte : limitez à ≤2 les tâches longues garées simultanément (le jitter de réveil évite la ruée, mais la fenêtre reste partagée).
- Si la fenêtre de 7 jours est épuisée, un reset 5h n'y changera rien ; les attentes dépassant `max_wait_hours` vous notifient et s'arrêtent au lieu d'attendre des jours.

## Développement

```bash
tests/run_tests.sh    # 25 tests unitaires : échantillonnage, gating, statusline, réveil, aller-retour d'installation
```

Licence MIT.
