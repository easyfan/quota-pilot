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
| `ttb_critical_minutes` | 3 | temps projeté avant épuisement déclenchant directement critical |
| `ttb_warn_minutes` | 10 | temps projeté déclenchant warn sous le seuil de % |

## Intégrations

L'alerte du hook est la ligne de défense *passive* ; les boucles et workflows multi-phases doivent interroger activement : `quota_report.sh --json` fournit `suggested_defer_seconds` (0 sous le seuil d'alerte, sinon secondes jusqu'au reset de la fenêtre). Les boucles reportent leur prochaine itération après le reset ; les workflows multi-phases vérifient aux frontières de phase (le point de stationnement le plus propre) — pattern prêt à l'emploi dans [`patterns/quota-phase-gate.md`](patterns/quota-phase-gate.md). Les sous-agents n'archivent pas eux-mêmes (réveils orphelins) mais rendent compte à la session principale. Détails : [README.md](README.md) §Integrations.

## Limites

- **Comptes abonnement (Pro/Max) uniquement.** Les comptes à clé API n'ont pas de fenêtres de quota ; le plugin le détecte et reste dormant — zéro surcoût, zéro bruit.
- L'échantillonneur primaire utilise l'endpoint non documenté `oauth/usage` ; chaque réponse est validée par schéma et tout écart retombe en silence, jamais en fausse alerte.
- Le quota est au niveau du compte : limitez à ≤2 les tâches longues garées simultanément (le jitter de réveil évite la ruée, mais la fenêtre reste partagée).
- Si la fenêtre de 7 jours est épuisée, un reset 5h n'y changera rien ; les attentes dépassant `max_wait_hours` vous notifient et s'arrêtent au lieu d'attendre des jours.

## Développement

```bash
tests/run_tests.sh    # 31 tests unitaires : échantillonnage, gating, burn-rate, statusline, réveil, --json, aller-retour d'installation
```

## Journal des modifications

### v0.3.0 (2026-07-14)

Récupération après mort du processus — l'alarme de réveil vit dans le processus de session ; un terminal fermé / redémarrage / park abandonné laisse le checkpoint orphelin sans rien pour réveiller automatiquement (incident 2026-07-13 : le processus est mort pendant l'attente, checkpoint retrouvé à la main 13,5 h plus tard).

| Élément | Changement |
|---------|-----------|
| Hook SessionStart de récupération | nouveau `quota_recover.sh` fait remonter un `quota-checkpoint.md` résiduel au prochain démarrage à froid |
| Park vivant vs orphelin | `quota_alarm.sh` écrit `alarm.pid` pendant l'attente ; le hook se tait tant que ce PID est vivant (et sur `resume`), ne parle que pour un vrai orphelin |
| Sortie de secours | l'avis indique de `rm` le checkpoint si vous ne comptez pas reprendre |
| Installateur | enregistre/retire le hook SessionStart de façon idempotente ; `install.sh` affiche `Done! N file(s)` / `Dry run: N file(s)` |

Revu par le comité skill-review (5 confirmés, 3 corrigés ; 2 rejetés). Couverture comportementale dans `tests/run_tests.sh` (43 cas).

Voir [README.md](README.md) pour les notes de version complètes en anglais.

### v0.2.2 (2026-07-14)

Suite de l'escalade par taux de consommation de v0.2.1 — supprimer les faux positifs dus aux pics de règlement. Incident 2026-07-13 : un saut d'échantillon 36%→59% en 66s a mis une session en pause à 65% alors qu'il restait 4,5h de fenêtre.

| Élément | Changement |
|---------|-----------|
| Portée d'observation min. | projection uniquement si la portée des échantillons ≥ `ttb_min_span_seconds` (180) |
| Minimum des taux | taux projeté = `min(fenêtre, dernier intervalle)` — un pic qui s'aplatit cesse de projeter |
| Vrais bursts intacts | les bursts rapides soutenus escaladent toujours ; un « plancher d'utilisation » a été évalué puis rejeté |

Voir [README.md](README.md) pour les notes de version complètes en anglais.

### v0.2.1 (2026-07-13)

Corrections après incident réel (burn rapide : session coupée 35 s après l'alerte critical, réveil jamais démarré) :

| Élément | Changement |
|---------|------------|
| Réveil d'abord | protocole d'archivage inversé : réveil avant checkpoint |
| Escalade burn-rate | le gate projette le temps avant épuisement : ≤3 min → critical, ≤10 min → warn |
| Résilience au réveil | checkpoint manquant → reconstruire l'état depuis le contexte |

Notes complètes : [README.md](README.md).

### v0.2.0 (2026-07-12)

| Élément | Changement |
|---------|------------|
| `quota_report.sh --json` | sortie machine avec `suggested_defer_seconds` |
| Branche sous-agent | les sous-agents rendent compte au lieu de créer des réveils orphelins |
| `patterns/quota-phase-gate.md` | pattern de porte aux frontières de phase avec patch-anchor |

Notes de version complètes en anglais : [README.md](README.md).

### v0.1.0 (2026-07-11)

Version initiale.

Licence MIT.
