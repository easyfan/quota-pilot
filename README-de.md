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
| `ttb_critical_minutes` | 3 | prognostizierte Zeit bis zur Erschöpfung, die direkt critical auslöst |
| `ttb_warn_minutes` | 10 | prognostizierte Zeit, die unterhalb der %-Schwelle warn auslöst |

## Integrationen

Der Hook-Alarm ist die *passive* Verteidigungslinie; Loops und mehrstufige Workflows sollten aktiv abfragen: `quota_report.sh --json` liefert `suggested_defer_seconds` (0 unterhalb der Warnschwelle, sonst Sekunden bis zum Fenster-Reset). Loops verschieben damit ihre nächste Iteration hinter den Reset; mehrstufige Workflows prüfen an Phasengrenzen (sauberster Parkpunkt) — fertiges Pattern in [`patterns/quota-phase-gate.md`](patterns/quota-phase-gate.md). Subagenten archivieren nicht selbst (verwaiste Wecker), sondern melden an die Hauptsession zurück. Details: [README.md](README.md) §Integrations.

## Grenzen

- **Nur Abo-Konten (Pro/Max).** API-Key-Konten haben keine Kontingentfenster; das Plugin erkennt das und bleibt inaktiv — null Overhead, null Rauschen.
- Der primäre Sampler nutzt den undokumentierten `oauth/usage`-Endpunkt; jede Antwort wird schema-validiert, jede Abweichung führt zu Stille, nie zu Fehlalarmen.
- Das Kontingent gilt kontoweit: höchstens 2 gleichzeitig geparkte Langläufer (der Weck-Jitter verhindert Anstürme, aber das Fenster bleibt geteilt).
- Ist das 7-Tage-Fenster erschöpft, hilft kein 5h-Reset; Wartezeiten über `max_wait_hours` benachrichtigen und stoppen, statt tagelang zu warten.

## Entwicklung

```bash
tests/run_tests.sh    # 31 Unit-Tests: Sampling, Gating, Burn-Rate, Statusline, Wecker, --json, Install-Roundtrip
```

## Changelog

### v0.2.2 (2026-07-14)

Folgemaßnahme zur Burn-Rate-Eskalation aus v0.2.1 — Fehlalarme durch Abrechnungs-Spitzen unterdrücken. Vorfall 2026-07-13: ein Sampler-Sprung 36%→59% in 66s pausierte eine Sitzung bei 65%, obwohl noch 4,5h Fenster übrig waren.

| Punkt | Änderung |
|-------|----------|
| Mindest-Beobachtungsspanne | Projektion nur bei Sample-Spanne ≥ `ttb_min_span_seconds` (180) |
| Minimum der Raten | projizierte Rate = `min(Fenster, letztes Intervall)` — eine abflachende Spitze projiziert nicht weiter |
| Echte Bursts unberührt | anhaltende schnelle Bursts eskalieren weiterhin; ein „Auslastungs-Floor" wurde geprüft und verworfen |

Siehe [README.md](README.md) für die vollständigen englischen Release Notes.

### v0.2.1 (2026-07-13)

Korrekturen nach Praxisvorfall (schnelles Burn: Session 35s nach Critical-Alarm abgeschnitten, Wecker nie gestartet):

| Punkt | Änderung |
|-------|----------|
| Wecker zuerst | Archivprotokoll umgekehrt: erst Wecker, dann Checkpoint |
| Burn-Rate-Eskalation | Gate prognostiziert Zeit bis Erschöpfung: ≤3 min → critical, ≤10 min → warn |
| Aufwach-Resilienz | fehlender Checkpoint → Zustand aus Konversationskontext rekonstruieren |

Vollständige Notes: [README.md](README.md).

### v0.2.0 (2026-07-12)

| Punkt | Änderung |
|-------|----------|
| `quota_report.sh --json` | maschinenlesbare Ausgabe mit `suggested_defer_seconds` |
| Subagent-Zweig | Subagenten melden zurück statt verwaiste Wecker zu starten |
| `patterns/quota-phase-gate.md` | Phasengrenzen-Gate-Pattern mit patch-anchor |

Vollständige englische Release Notes: [README.md](README.md).

### v0.1.0 (2026-07-11)

Erstveröffentlichung.

MIT-Lizenz.
