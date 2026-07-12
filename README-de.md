# quota-pilot

**Kontingentbewusste Aufgabenplanung für Claude Code.** Lange Aufgaben prallen nicht mehr gegen die 5-Stunden-Rate-Limit-Wand: Bevor das Fenster erschöpft ist, bewertet die Session die verbleibende Arbeit, schreibt einen Checkpoint, stellt sich einen Wanduhr-Wecker, wartet ohne Token-Kosten im Leerlauf und setzt nach dem Reset automatisch fort.

[English](README.md) | [中文](README-zh.md) | [Français](README-fr.md) | [Русский](README-ru.md)

## Warum proaktiv?

Bestehende Tools (claude-auto-retry u. a.) sind **reaktiv**: Sie lassen die Session am Rate-Limit sterben und tippen dann blind „continue" per tmux hinein. Das scheitert dreifach — der Abbruch trifft meist mitten in einen Turn (Edit gemacht, Tests nie gelaufen), sodass das fortgesetzte Modell falsch einschätzt, was wirklich fertig ist; es braucht tmux-Tasteneingaben in eine tote Session; und es hat null Voraussicht über das verbleibende Budget.

quota-pilot dreht es um: **Die Session stirbt nie.** Sie wird *vor* der Erschöpfung gewarnt, beurteilt selbst, ob die nächste unteilbare Arbeitseinheit noch passt, archiviert ehrlich (inklusive dessen, was halbfertig und unverifiziert ist) und weckt sich selbst wieder auf. Kein tmux, kein launchd, kein externer Babysitter — nur native Claude-Code-Primitive.

## Funktionsweise

```
┌─ Sampling ────────────────┐   ┌─ Entscheidung ───────┐   ┌─ Verhalten (Modell) ─────┐
│ primär: oauth/usage-Poll  │   │ PostToolUse-Hook     │   │ quota-pilot-Skill        │
│ (gedrosselt im Hook,      │ → │ liest state.json     │ → │ 1. nächste Einheit prüfen│
│  in ALLEN Sessions aktiv) │   │ Schwellwert+Cooldown │   │ 2. Checkpoint schreiben  │
│ aux: Statusline-Wrapper   │   │ injiziert Alarm      │   │ 3. Wanduhr-Wecker        │
│ (nur TUI-Anzeige)         │   └──────────────────────┘   │ 4. Idle → Wecken → weiter│
└───────────────────────────┘                              └──────────────────────────┘
```

- **warn** (Standard 88 %): Das Modell prüft, ob die nächste unteilbare Einheit ins Restbudget passt (3 % Checkpoint-Reserve). Wenn ja, weiterarbeiten; wenn nein, archivieren und parken.
- **critical** (Standard 95 %): Prüfung überspringen, sofort archivieren.
- Der Checkpoint (`<Projekt>/.claude/quota-checkpoint.md`) trennt *fertig-und-verifiziert* von *in-Arbeit-unverifiziert* — genau diese Unterscheidung beseitigt Blind-Resume-Fehler.
- Der Wecker ist eine Wanduhr-Schleife, kein einzelnes langes `sleep`: Die monotone Uhr von macOS steht während des Systemschlafs still, ein `sleep 4h` bei zugeklapptem Laptop verschläft also um Stunden. Die Schleife erkennt eine verpasste Deadline binnen 60 s nach dem Aufwachen der Maschine.

## Installation

**Variante A — Installationsskript:**

```bash
git clone https://github.com/easyfan/quota-pilot.git
cd quota-pilot
./install.sh                # Hook + Skill + /quota-Befehl
./install.sh --statusline   # zusätzlich TUI-Kontingentanzeige
```

`--statusline` bewahrt eine vorhandene statusLine: Der ursprüngliche Befehl rendert weiter durch den Wrapper, während Kontingentdaten nebenbei erfasst werden.

**Variante B — Plugin-Marketplace:**

```
/plugin marketplace add easyfan/quota-pilot
/plugin install quota-pilot@quota-pilot
```

Deinstallation: `./install.sh --uninstall` (stellt ursprüngliche statusLine und Settings wieder her; der Zustand unter `~/.claude/quota-pilot/` bleibt erhalten, bei Bedarf manuell löschen).

## Nutzung

Nichts zu tun — der Hook überwacht das Kontingent bei jedem Tool-Aufruf (gedrosselt max. eine HTTPS-Anfrage pro 60 s). Bei einem Alarm sieht man das Modell bewerten, archivieren und sich selbst parken.

- `/quota` — aktuelle 5h/7d-Auslastung, Reset-Countdown, Burn-Rate, Erschöpfungsprognose
- `touch ~/.claude/quota-pilot/cancel` — geparkte Session vorzeitig wecken
- Der Checkpoint liegt unter `<Projekt>/.claude/quota-checkpoint.md`; stirbt der Prozess während des Parkens, kann eine frische Session daraus fortsetzen

## Konfiguration (`~/.claude/quota-pilot/config.json`)

| Schlüssel | Standard | Bedeutung |
|-----------|----------|-----------|
| `warn_threshold` | 88 | Schwellwert Bewertungsalarm (5h-Fenster %) |
| `critical_threshold` | 95 | Schwellwert Sofort-Archivierung |
| `reserve` | 3 | zurückgehaltenes Checkpoint-Budget (%) |
| `cooldown_minutes` | 10 | Cooldown pro Alarmstufe |
| `max_wait_hours` | 6 | darüber hinaus Mensch benachrichtigen statt warten |
| `wake_jitter_minutes` | 5 | zufälliger Weck-Jitter (Schutz vor Multi-Session-Ansturm) |
| `seven_day_warn` | 90 | Benachrichtigungsschwelle 7-Tage-Fenster (nur Hinweis) |

## Grenzen

- **Nur Abo-Konten (Pro/Max).** API-Key-Konten haben keine Kontingentfenster; das Plugin erkennt das und bleibt inaktiv — null Overhead, null Rauschen.
- Der primäre Sampler nutzt den undokumentierten `oauth/usage`-Endpunkt; jede Antwort wird schema-validiert, jede Abweichung führt zu Stille, nie zu Fehlalarmen.
- Das Kontingent gilt kontoweit: höchstens 2 gleichzeitig geparkte Langläufer (der Weck-Jitter verhindert Anstürme, aber das Fenster bleibt geteilt).
- Ist das 7-Tage-Fenster erschöpft, hilft kein 5h-Reset; Wartezeiten über `max_wait_hours` benachrichtigen und stoppen, statt tagelang zu warten.

## Entwicklung

```bash
tests/run_tests.sh    # 25 Unit-Tests: Sampling, Gating, Statusline, Wecker, Install-Roundtrip
```

MIT-Lizenz.
