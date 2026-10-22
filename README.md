# Dump Bicep di Azure API Management

`Dump-ApimArm.ps1` usa PowerShell 7 e Azure CLI (`az login`) per leggere l'istanza
`apim-openailg` nel gruppo `rg-openai`. Richiede accesso in lettura alle risorse APIM
e accesso ai contenuti del Developer Portal. Esegue solo letture, salvo la richiesta
POST `listSecrets` necessaria per ottenere l'URL temporaneo dei media.

```powershell
.\Dump-ApimArm.ps1
# Oppure con un percorso e un'istanza differenti:
.\Dump-ApimArm.ps1 -SubscriptionId <id> -ResourceGroupName <gruppo> -ServiceName <nome> -OutputDirectory .\dump
# Per escludere le risorse già gestite da ApiOps:
.\Dump-ApimArm.ps1 -SubscriptionId <id> -ResourceGroupName <gruppo> -ServiceName <nome> -OutputDirectory .\dump -NoApis
# Per configurare un'istanza esistente senza esportare sottoscrizioni, utenti e gruppi:
.\Dump-ApimArm.ps1 -SubscriptionId <id> -ResourceGroupName <gruppo> -ServiceName <nome> -OutputDirectory .\dump -AsExisting -NoSubscriptions -NoUsersGroups
```

`-OutputDirectory` accetta percorsi assoluti o relativi, anche se la directory
non esiste ancora. I percorsi relativi sono risolti rispetto alla posizione
PowerShell corrente (`$PWD`), non alla directory del processo (che puo' essere
`C:\Windows\System32`). Tutti i file e le sottocartelle del dump sono creati
sotto la directory di output risolta.

Il Bicep espone `param serviceName string` con valore predefinito uguale al nome
dell'istanza esportata. Nomi delle risorse figlie e riferimenti ARM interni
all'istanza usano il parametro, inclusi gli ID nelle proprieta' annidate.
Il parametro non modifica i file HTML/XML o gli URL e gli altri metadati del
servizio sorgente, che restano uno snapshot.

I flag sono combinabili:

- `-NoSubscriptions` omette le sottoscrizioni APIM, incluse quelle dei workspace
  (non si riferisce alle sottoscrizioni Azure).
- `-NoUsersGroups` omette utenti, gruppi, appartenenze, associazioni dei prodotti
  ai gruppi e destinatari utenti delle notifiche, anche nei workspace.
  Non elimina eventuali riferimenti a utenti/gruppi nelle proprieta' delle
  risorse conservate: questi devono gia' esistere nella destinazione.
- `-AsExisting` dichiara la risorsa padre APIM come `existing`, senza `properties`,
  SKU, identita', tag o location; le risorse figlie rimangono distribuibili.

I content type standard del Developer Portal (`page`, `document`, `layout`,
`blogpost`, `blob`, `url`, `navigation`, `block`, `popup`) e
`portalsettings/delegation` e `portalsettings/default` sono sempre dichiarati `existing`, senza
`properties`, come nel Bicep di riferimento. I content type personalizzati e
i content item non diventano `existing`. Non serve il file di riferimento
per eseguire lo script. `report.json` registra `noSubscriptions`,
`noUsersGroups` e `asExisting`, oltre a `noApis`.

`-NoApis` esclude le risorse coperte dalla tabella
[Supported Scenarios di ApiOps](https://azure.github.io/apiops/apiops/1-supportedScenarios/):
API (incluse operazioni, policy, diagnostica, version set e GraphQL), backend,
policy globali e frammenti, named value, logger, diagnostica, gateway e loro
associazioni API, prodotti e relative associazioni API/gruppi, policy e tag.
L'istanza APIM, il Developer Portal e le sottorisorse non elencate da ApiOps
(per esempio release, wiki, utenti, workspace e configurazioni gateway)
rimangono nel dump. Lo script attraversa anche i genitori esclusi per
raggiungere eventuali discendenti non coperti; `report.json` indica `noApis`.

Le proprieta' read-only restituite dalle API sono eliminate **per tipo e
percorso** prima della generazione del Bicep (incluse le proprieta' annidate
di identita' e private endpoint). Il report `removedReadOnlyProperties`
elenca ogni percorso rimosso e il numero di occorrenze. Le regole derivano
dagli avvisi `BCP073` del linter Bicep e dalle definizioni
[APIM 2024-05-01](https://learn.microsoft.com/en-us/azure/templates/microsoft.apimanagement/2024-05-01/service).
Il linter viene eseguito a ogni dump: se non riesce o trova un nuovo `BCP073`,
lo script emette un warning ma **non interrompe l'esportazione**.
`report.json` riporta `bicepLintExitCode`, `readOnlyBicepWarnings` e
`otherBicepWarnings`. Gli altri avvisi non sono necessariamente read-only
e non vengono eliminati automaticamente.

Il risultato e' una cartella `apim-openailg-<timestamp>` con `main.bicep`
(sorgente Bicep con parametro `serviceName`),
`portal-media\` (blob binari del Developer Portal), `html\`, `policies\` e `report.json`
(conteggi ed eventuali collection che rispondono 404). Lo script enumera le
collection di risorse APIM annidate, incluse API, revisioni come API, operazioni,
policy, prodotti, workspace, content type e content item del Developer Portal.
Usa l'API `2024-05-01` e le versioni preview per i tipi introdotti successivamente;
segue tutte le pagine `nextLink`. I media sono salvati separatamente perche'
non sono risorse ARM. I content item binari non conservano `downloadUrl`: hanno
`data: loadFileAsBase64('./portal-media/<fileName>')`. Nei nomi locali dei media
e dei blob orfani, `/` viene sostituito con `_`, senza modificare i metadati
originali o gli URL di download. Le omonimie di `fileName`
sono disambiguate con `_<blobId>` prima dell'estensione; per i blob orfani
si usa un suffisso numerico, evitando sovrascritture. I file oltre 90 KiB
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

## Test

```powershell
.\tests\Dump-ApimArm.Tests.ps1
```

I test usano risposte ARM e storage simulate, senza autenticazione o accesso a
risorse Azure. Richiedono PowerShell 7, Azure CLI e il compilatore Bicep gia'
installato (`az bicep version`). Verificano i flag singolarmente e combinati,
la compatibilita' con `-NoApis`, le dichiarazioni `existing`, i riferimenti
parametrizzati e l'estrazione HTML/XML compilando realmente il Bicep prodotto.
Verificano anche percorsi di output relativi e assoluti con spazi, mantenendo
diverse la directory PowerShell e quella del processo.
