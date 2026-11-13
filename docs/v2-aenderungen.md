# v2 ändern: Vorschlag, Vorschau, Promotion

v2 wird zentral gesteuert und darf nachgeschärft werden. Damit vorher bekannt ist, welche Repos davon betroffen wären, läuft jede Änderung zuerst über die `*.next.json`-Dateien.

## Änderung vorschlagen

1. In einem PR die Kandidatendateien ändern: `SOCITAS.ruleset.v2.next.json`, `SOCITAS.test.ruleset.v2.next.json` (wird mit `tools/Build-TestRuleset.ps1` aus dem App-Ruleset erzeugt, nie von Hand) und/oder `SOCITAS.analyzers.v2.next.json`. Die aktuellen v2-Dateien bleiben unverändert.
2. PR mergen. Solange nichts vorgeschlagen ist, sind die `next`-Dateien byte-identisch zu den aktuellen.
3. Das CI der v2-Repos kompiliert auf main/stage/dev den Kandidaten als Vorschau (`previewRuleset = v2.next`, OperationName `CI Preview Compile`) und meldet `wouldFailBuild` als Telemetrie. Der echte Build ändert sich nicht.
4. Auswirkung prüfen:
   `pwsh tools/Get-V2ImpactReport.ps1 -WorkspaceId <Log-Analytics-Workspace-ID> [-CandidateHash <Hash-App>,<Hash-Test>] [-OutPath report.json]`
   Pro v2-App, App-Art (app/test) und Branch (main/stage/dev) steht `pass`, `fail`, `identical` oder `not evaluated` (Timeout, übersprungen, kein Ergebnis; `(stale)` = Ergebnis stammt von einem anderen Kandidaten-Hash). Offline mit `-RowsPath <rows.json>`.
5. Promotion-PR: Inhalt der `next`-Dateien 1:1 in die aktuellen v2-Dateien kopieren. `tools/Test-V2Promotion.ps1 -BaseRef origin/<Zielbranch>` (läuft im PR-Check) lässt eine Änderung an einer v2-Datei nur zu, wenn sie dem `next` der jeweiligen Datei auf dem Zielbranch entspricht. Die v1-Dateien (`SOCITAS.ruleset.json`, `SOCITAS.test.ruleset.json`) dürfen sich nie ändern.

## Pin-Bump (Analyzer-Versionen)

1. Pins in `SOCITAS.analyzers.v2.next.json` anheben (`revision` erhöhen).
2. Inventar neu erzeugen:
   `pwsh tools/Get-RuleInventory.ps1 -PinsPath SOCITAS.analyzers.v2.next.json -OutPath v2/rule-inventory.next.json`
3. Für neue Regel-IDs in `SOCITAS.ruleset.v2.next.json` ausdrücklich eine Aktion eintragen, danach das Test-Ruleset neu generieren. Die Abdeckungsprüfung im CI erzeugt das Inventar immer neu aus `SOCITAS.analyzers.v2.next.json` (kein Rückgriff auf das aktuelle Inventar; das Inventar trägt die Pins, aus denen es erzeugt wurde, im Feld `pins`) und schlägt bei jeder ID ohne Aktion fehl.
4. Weiter wie oben (Vorschau, Report, Promotion). Bei der Promotion `v2/rule-inventory.json` mit dem neuen Inventar ersetzen und `v2/rule-inventory.next.json` entfernen oder angleichen.
