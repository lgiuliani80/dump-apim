# Dump Bicep di Azure API Management

`Dump-ApimArm.ps1` usa PowerShell 7 e Azure CLI (`az login`) per leggere l'istanza
`apim-openailg` nel gruppo `rg-openai`. Richiede accesso in lettura alle risorse APIM
e accesso ai contenuti del Developer Portal. Esegue solo letture, salvo la richiesta
POST `portalconfigs/default/listMediaContentSecrets?api-version=2021-08-01`
necessaria per ottenere l'URL temporaneo dei media. Lo script di upload generato
scrive invece nello storage del servizio APIM di destinazione.
Mantenere `Upload-PortalMedia.ps1` accanto allo script di dump: viene copiato
nella cartella di output per rendere il risultato autonomo.

```powershell
# Per configurare un'istanza esistente senza esportare api, sottoscrizioni, utenti e gruppi:
.\Dump-ApimArm.ps1 -SubscriptionId <id> -ResourceGroupName <gruppo> -ServiceName <nome> -OutputDirectory .\dump -AsExisting -NoApis -NoSubscriptions -NoUsersGroups
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
Le stesse esclusioni si applicano nei workspace. I rami esclusi vengono saltati
prima di qualunque richiesta, incluse enumerazione delle collection e lettura
dei discendenti (quindi anche release, wiki e configurazioni dei gateway esclusi).
L'istanza APIM, il Developer Portal, i workspace e gli altri rami non esclusi
rimangono nel dump. `report.json` indica i flag attivi e `armRequests` elenca
metodo e percorso relativo di ogni richiesta ARM effettuata, senza token o SAS.
Un controllo centralizzato blocca anche eventuali `nextLink` verso tipi esclusi
o percorsi esterni al servizio.

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
`portal-media\` (blob binari del Developer Portal), `html\`, `policies\`, `report.json`,
`Upload-PortalMedia.ps1`, `portal-media-manifest.json` e `portal-media-urls.json`
(conteggi ed eventuali collection che rispondono 404). Lo script enumera le
collection di risorse APIM annidate, incluse API, revisioni come API, operazioni,
policy, prodotti, workspace, content type e content item del Developer Portal.
Usa l'API `2024-05-01` e le versioni preview per i tipi introdotti successivamente;
segue tutte le pagine `nextLink`. I media sono salvati separatamente perche'
non sono risorse ARM. I content item binari conservano `downloadUrl`, letto dal
dizionario `portal-media-urls.json` mediante `loadJsonContent()` nel Bicep;
non contengono `data` o contenuti Base64. Nei nomi locali dei media
e dei blob orfani, `/` viene sostituito con `_`, senza modificare i metadati
originali o gli URL di download. Le omonimie di `fileName`
sono disambiguate con `_<blobId>` prima dell'estensione; per i blob orfani
si usa un suffisso numerico, evitando sovrascritture. I file restano interi:
non sono suddivisi in chunk ne' incorporati nel template. Il manifest conserva
la corrispondenza fra file locale, nome blob originale e MIME type.
I contenuti HTML e le policy XML sono
estratti come `.html`/`.xml` e richiamati con `loadTextContent()`.

Il sorgente Bicep viene compilato localmente dallo script per validarlo, ma non
viene conservato un template ARM JSON. `loadTextContent()` e `loadJsonContent()`
sono valutate in compilazione, non a deployment. I binari non contribuiscono
alla dimensione del template ARM; le altre risorse possono comunque superare
il limite ARM di 4 MiB. `report.json` include
`compiledArmBytes`, `fitsSingleArmDeployment` e
gli eventuali blob orfani privi di un content item da cui ricavare `fileName`.

## Upload dei media prima del deployment

L'istanza APIM di destinazione deve gia' esistere: se il Bicep deve crearla,
provisionarla prima di eseguire l'upload. Dopo `az login`, dalla cartella di
output eseguire:

```powershell
.\Upload-PortalMedia.ps1 -SubscriptionId <id-destinazione> -ResourceGroupName <gruppo-destinazione> -ServiceName <nome-destinazione>
# Solo dopo l'upload, compilare o distribuire main.bicep:
az deployment group create --subscription <id-destinazione> --resource-group <gruppo-destinazione> --template-file .\main.bicep --parameters serviceName=<nome-destinazione>
```

Lo script usa `az rest` per ottenere la SAS tramite
`POST {serviceResourceId}/portalconfigs/default/listMediaContentSecrets?api-version=2021-08-01`
e `az storage blob upload` per caricare tutti i file del manifest, inclusi
i blob orfani, con nome blob e MIME type originali. `--overwrite true` permette
di rieseguire l'upload. Non distribuisce risorse ARM e non pubblica il portale.

Solo quando tutti gli upload riescono, aggiorna atomicamente il dizionario
`portal-media-urls.json` (`blobId` -> URL blob di destinazione **senza SAS**).
In caso di errore interrompe l'esecuzione senza aggiornare il JSON; i blob
gia' caricati non vengono rimossi. Il dizionario iniziale contiene le URL dello
storage sorgente. La SAS e' usata solo in memoria tramite la variabile ambiente
`AZURE_STORAGE_SAS_TOKEN`, ripristinata al termine; non viene scritta nei file.
I percorsi dei file sono relativi alla posizione dello script, non a `$PWD`.
**Ricompilare sempre il Bicep dopo l'upload**: un template ARM compilato in
precedenza conserva le vecchie URL. Usare lo stesso nome APIM per l'upload e
per il parametro `serviceName`.

Le `PortalRevision` sono sempre ignorate: lo script non ne legge gli endpoint
e non le include nel Bicep. Il dump non ricrea lo storico delle pubblicazioni
e non pubblica automaticamente il portale.

Quando la GET di un identity provider non restituisce ne' `clientSecret` ne'
`certificateId`, il Bicep richiede il parametro **secure object**
`identityProviderClientSecrets`, con una chiave per ogni provider (es. `aad`).
Il dump non legge automaticamente i segreti: emette un warning e li elenca in
`report.json` come `requiredIdentityProviderClientSecrets`. Fornirli tramite
un canale sicuro al deployment; non inserirli nel sorgente Bicep o in file
versionati. Le credenziali leggibili tramite l'operazione ARM `listSecrets`
possono essere recuperate separatamente con autorizzazioni adeguate.

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
I test includono media da 5 MiB senza chunking/Base64, nomi file duplicati,
blob orfani, download di fallback, upload simulato, errore di upload parziale,
ripristino della SAS e ricompilazione con le URL di destinazione.
