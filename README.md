# Dump Bicep di Azure API Management

`Dump-ApimArm.ps1` usa PowerShell 7 e Azure CLI (`az login`) per leggere l'istanza
`apim-openailg` nel gruppo `rg-openai`. Richiede accesso in lettura alle risorse APIM
e accesso ai contenuti del Developer Portal. Esegue solo letture, salvo la richiesta
POST `listSecrets` necessaria per ottenere l'URL temporaneo dei media.

```powershell
.\Dump-ApimArm.ps1
# Oppure con un percorso e un'istanza differenti:
.\Dump-ApimArm.ps1 -SubscriptionId <id> -ResourceGroupName <gruppo> -ServiceName <nome> -OutputDirectory .\dump
```

Il risultato e' una cartella `apim-openailg-<timestamp>` con `main.bicep`
(sorgente Bicep senza parametri o variabili),
`portal-media\` (blob binari del Developer Portal), `html\`, `policies\` e `report.json`
(conteggi ed eventuali collection che rispondono 404). Lo script enumera le
collection di risorse APIM annidate, incluse API, revisioni come API, operazioni,
policy, prodotti, workspace, content type e content item del Developer Portal.
Usa l'API `2024-05-01` e le versioni preview per i tipi introdotti successivamente;
segue tutte le pagine `nextLink`. I media sono salvati separatamente perche'
non sono risorse ARM. I content item binari non conservano `downloadUrl`: hanno
`data: loadFileAsBase64('./portal-media/<fileName>')`. Le omonimie di `fileName`
sono disambiguate con `_<blobId>` prima dell'estensione. I file oltre 90 KiB
sono anche suddivisi in `portal-media\parts\<blobId>\` per rispettare il limite
di 96 KiB di `loadFileAsBase64`: il campo `data` usa `concat` delle parti, mentre
il file originale rimane disponibile. I contenuti HTML e le policy XML sono
estratti come `.html`/`.xml` e richiamati con `loadTextContent()`.

Il sorgente Bicep viene compilato localmente dallo script per validarlo, ma non
viene conservato un template ARM JSON. `loadTextContent()` e `loadFileAsBase64()`
sono funzioni Bicep valutate in compilazione, non funzioni ARM JSON. Con media
di grandi dimensioni il template ARM compilato puo' superare il limite ARM di
4 MiB e non essere distribuibile come singolo deployment. `report.json` include
`compiledArmBytes`, `fitsSingleArmDeployment`, il numero di file suddivisi e
gli eventuali blob orfani privi di un content item da cui ricavare `fileName`.

**Limitazioni:** un dump ARM non puo' recuperare segreti che il provider non
restituisce; il sorgente rispecchia le risposte GET e puo' contenere proprieta'
di sola lettura. Non e' una garanzia di redeploy immediato. Controllare
`report.json` per gli endpoint non disponibili: quando una collection risponde
404 non e' possibile attestare che sia vuota, percio' il report non certifica
la completezza assoluta. Non pubblicare la cartella:
il contenuto puo' includere policy, dati degli utenti e altri valori sensibili.
