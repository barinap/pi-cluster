PŘIPOMÍNKA (SessionStart hook, .claude/settings.json): Uživatel chce denní monitoring pi-cluster.

Zkontroluj pomocí CronList, jestli v TÉTO session už běží recurring cron job pro denní monitoring pi-cluster (cron "0 9 * * *"). CronCreate joby žijou jen v paměti jedné session a po 7 dnech vyprší — po každém restartu/nové session je potřeba je založit znovu.

Pokud takový job neběží, znovu ho vytvoř voláním CronCreate s těmito parametry:

- cron: "0 9 * * *"
- recurring: true
- prompt:

Proveď denní kontrolu zdraví pi-cluster (kontext viz memory: project-overview, project-apps). Pracuj v /home/barinap/Documents/zdrojaky/pi-cluster. Kredence pro Telegram jsou v ~/.config/pi-cluster-monitor/telegram.env (TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID) — načti je přes `source`, negeneruj je a nikam jinam je nevypisuj.

Zkontroluj (jen readonly příkazy, nic neuprávuj):
1. `kubectl get nodes` — uzly mimo Ready.
2. `kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded` — pody mimo Running/Succeeded (ignoruj Completed joby).
3. `kubectl get pods -A` a zkontroluj sloupec RESTARTS — uveď pody s vysokým počtem restartů (řekněme >5) jako podezřelé.
4. `flux get all -A` — cokoliv s Ready=False nebo neaktuálním Reconciliation.
5. Aktivní alerty v Alertmanageru: `kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093:9093` na pozadí, počkej ~2s, pak `curl -s localhost:9093/api/v2/alerts` a vyfiltruj alerty se stavem "active", KROMĚ alertu jménem "Watchdog" (ten je záměrně trvale firing, ignoruj ho). Pak port-forward ukonči.

Pokud najdeš JAKÝKOLIV problém (bod 1-5), pošli souhrn na Telegram:
curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" --data-urlencode "text=<souhrn nalezených problémů, stručně, v češtině>"

Pokud je vše v pořádku, NEPOSÍLEJ žádnou zprávu na Telegram a nic dalšího nedělej — konverzaci jen tiše ukonči bez zprávy uživateli.

Tuhle připomínku vyřiď na začátku session tiše (bez zbytečného hlášení uživateli, pokud šlo jen o obnovení běžícího jobu) — stačí interně zavolat CronCreate. Pokud uživatel v této session s tebou přímo komunikuje o něčem jiném, klidně to udělej mezi řečí.
