# Жесткий code review: proxy/VPN core, split tunneling, geodata, UI

Scope: статический review текущего репозитория `teleport` на macOS Swift/SwiftUI приложение с Xray System Proxy и VPN/TUN режимом. Основной фокус: core proxy/VPN логика, privileged helper, route management, Xray config writer, split-tunnel/geodata UI и состояние приложения.

Проверки: код прочитан вручную. Runtime-проверки, live VPN-тесты, DNS/IPv6 leak tests и сборка в этом проходе не запускались.

---

## ✅ Исправлено в этой ветке (правки + тесты)

Внесены фиксы по находкам, которые **привнесла именно эта ветка** (баги с main —
IPv6/DNS leak и т.п. — не трогались, это отдельная тема). Сборка `xcodebuild` и все
verify-скрипты (`core`, `split_tunneling`, `geodata`) — зелёные.

| Находка | Файл | Что сделано | Тест |
|---|---|---|---|
| **НОВОЕ-1** голые домены → substring в Xray | `XrayConfigurationWriter.swift` | эмитим `domain:`-префикс (а `full:` — как есть) | `testDomainRuleEmitsDomainPrefixNotSubstring` |
| **1.7** data race на `appliedSplitTunnelRules` | `AppViewModel.swift` | запись перенесена в `Task { @MainActor }` (start + reconnect) | не покрывается скриптом (гонка потоков) |
| **НОВОЕ-2** запись geodata на main actor | `AppViewModel.swift` | `store()` выполняется на `geodataQueue` | косвенно `testStoreReportsWhetherBytesChanged` |
| **3.6-доп** reconnect при неизменном файле | `GeodataUpdateService.swift` + `AppViewModel.swift` | `store()` возвращает `changed`, reconnect только если `changed` | `testStoreReportsWhetherBytesChanged` |
| **НОВОЕ-4** сырой percent-encoded host | `ConnectionLinkParser.swift` | `removingPercentEncoding` с сохранением регистра | `testPercentEncodedHostIsDecoded` |
| **3.6-доп3** URL geodata без host | `AppViewModel.swift` | требуем непустой `components.host` | — (private, не достижимо из скрипта) |

Обновлён `scripts/verify_split_tunneling.swift` — ассерт доменного правила приведён
к новому корректному контракту (`domain:`-префикс) вместо старого «as-is».

**Сознательно не тронуто** (нужны продуктовые/архитектурные решения, не механический фикс):
НОВОЕ-3 (порядок правил vs служебные block-правила — влияет на routing-safety),
1.8 (тихий direct-loop при нерезолвленном интерфейсе — нужен выбор: surface-ошибка
vs ретрай), а также крупные рефакторинги из раздела 5 (god-object `AppViewModel`,
typed routing model, single source of truth для geodata-путей).

## 1. Жесткие баги в core-логике / proxy

### 1.1. VPN mode не туннелирует IPv6, что дает прямой traffic leak

Файлы:
- `teleport/Xray/XrayConfigurationWriter.swift:142-149`
- `TeleportPrivilegedHelper/main.swift:629-630`
- `TeleportPrivilegedHelper/main.swift:700-729`

TUN config содержит только IPv4 gateway `172.18.0.1/30` и `autoSystemRoutingTable: ["0.0.0.0/0"]`. Helper ставит только IPv4 split-default routes `0.0.0.0/1` и `128.0.0.0/1`. IPv6 default route не меняется и не блокируется.

Итог: на сетях с IPv6 часть трафика будет идти напрямую мимо Teleport VPN, split-tunnel rules и блокировок. Для VPN-продукта это критичный privacy/security leak.

### 1.2. DNS-запросы намеренно выводятся наружу из VPN

Файлы:
- `TeleportPrivilegedHelper/main.swift:641-642`
- `TeleportPrivilegedHelper/main.swift:731-732`
- `TeleportPrivilegedHelper/main.swift:883-901`

`protect_dns_routes()` берет публичные IPv4 DNS из `scutil --dns` и добавляет host routes к ним через physical gateway. Это означает, что системные DNS-запросы идут вне туннеля.

Последствия:
- домены видны провайдеру/локальной сети даже в VPN mode;
- destination-based domain rules зависят от Xray sniffing, а не от контролируемого DNS пути;
- QUIC/UDP, ECH, raw IP connects и non-sniffable flows могут не соответствовать тому, что пользователь ожидает от доменных правил.

Если это защита маршрута к proxy server, она реализована слишком широко: нельзя silently выводить наружу все публичные DNS resolvers.

### 1.3. Protected route к proxy server защищает hostname, а не полный набор resolved адресов

Файлы:
- `teleport/Connection/ConnectionBackendFactory.swift:51-66`
- `TeleportPrivilegedHelper/main.swift:638-640`
- `TeleportPrivilegedHelper/main.swift:906-912`

В helper передается только `configuration.host`. Скрипт делает `route -n get "$PROTECTED_HOST"`, берет один gateway и добавляет один host route для этого host.

Проблемы:
- hostname может иметь несколько A/AAAA адресов;
- DNS может измениться между route lookup и реальным connect Xray;
- IPv6 endpoint не покрывается вообще;
- Xray может резолвить endpoint иначе, чем shell-команда `route get`.

Итог: соединение к самому proxy server может уйти в TUN, зациклиться или нестабильно падать в зависимости от DNS ответа.

### 1.4. В VPN mode восстановление system proxy может включить чужой proxy поверх VPN

Файлы:
- `teleport/Connection/ConnectionBackendFactory.swift:45`
- `teleport/Proxy/SystemProxyService.swift:43-47`
- `teleport/Proxy/SystemProxyService.swift:60-72`

`XrayTunConnectionBackend.start()` вызывает `systemProxyService.disableProxy()`. Но `disableProxy()` при наличии snapshot не выключает proxy, а восстанавливает предыдущее состояние. Если до Teleport System Proxy у пользователя был корпоративный/локальный proxy, переход в VPN mode может вернуть этот proxy поверх VPN.

Итог: приложения, которые уважают macOS proxy settings, пойдут не просто через TUN, а через восстановленный system proxy. Это ломает ожидание “VPN routes the whole device”, создает неожиданный routing path и усложняет split-tunnel semantics.

### 1.5. IPv6 proxy endpoints фактически несовместимы с VPN mode

Файлы:
- `teleport/Parsing/ConnectionLinkParser.swift:162-173`
- `teleport/Connection/ConnectionBackendFactory.swift:64`
- `TeleportPrivilegedHelper/main.swift:346-371`

Parser берет `components.host`, то есть IPv6 literal потенциально может попасть в `ConnectionConfiguration.host`. Но privileged helper валидирует `protectedHost` через charset `A-Z a-z 0-9 . -`, запрещая `:`. В System Proxy mode такой config может пройти, а в VPN mode helper отвергнет запуск.

### 1.6. Existing VPN detection смотрит только IPv4 default route

Файл:
- `teleport/Xray/XrayTunRouteInspector.swift:15-40`

`existingVPNDefaultRouteInterface()` парсит только `netstat -rn -f inet`. IPv6-only или IPv6-preferred VPN/default route через `utun` не будет обнаружен. Teleport может стартовать поверх другого VPN и получить конфликт маршрутов или leak.

### 1.7. Data race на `appliedSplitTunnelRules` — фоновый поток пишет, main поток читает

Файл: `teleport/ViewModels/AppViewModel.swift:97, 740, 1015, 1048`

`appliedSplitTunnelRules` — обычный `private var` (не `@Published`, без синхронизации). Пишется на `operationQueue` (фоновая serial-очередь `dev.x.teleport.connection-operations`) после успешного `connectionBackend.start/reconnect(...)` (строки 1015, 1048), а читается на главном потоке из `applySplitTunnelRulesLiveIfNeeded()` (строка 740), вызываемой из `DispatchWorkItem`, запланированного через `DispatchQueue.main.asyncAfter` (debounce 0.7с в `scheduleSplitTunnelLiveApply`).

Сценарий: пользователь правит split-tunnel правила, пока в фоне доканчивается предыдущий `reconnect`. Main-поток читает `appliedSplitTunnelRules` ровно в момент, когда `operationQueue` его перезаписывает — незащищённое одновременное чтение/запись Swift-массива. В лучшем случае — неверный результат сравнения `activeSplitTunnelRules != appliedSplitTunnelRules` (пропущенный/лишний reconnect), в худшем — Swift exclusivity enforcement может поймать это как runtime trap. Thread Sanitizer найдёт однозначно.

Фикс: писать через `Task { @MainActor in self?.appliedSplitTunnelRules = ... }`, как уже сделано для `connectionPhase`/`proxyPhase` рядом в тех же функциях.

### 1.8. Split-tunnel "direct" правило молча ломается, если не удалось определить физический интерфейс

Файлы: `teleport/Xray/XrayConfigurationWriter.swift:117-129`, `teleport/Connection/ConnectionBackendFactory.swift` (цепочка `routeInspector.outboundInterface(for: host) ?? routeInspector.defaultRouteInterface() ?? "auto"`)

Комментарий в коде сам объясняет инвариант: "The default routes point every destination at the TUN, so a plain freedom outbound would loop split-tunnel direct traffic straight back into Xray." Bind к физическому интерфейсу происходит только если `outboundInterface != "auto" && !outboundInterface.isEmpty`. Если обе попытки резолва интерфейса вернут `nil` (нет активного дефолтного роута, Wi-Fi handoff, другой VPN ещё не до конца отключился), `outboundInterface` осядет на `"auto"`, `directOutbound` не получит `sockopt`, и direct-трафик зациклится обратно в TUN — по собственному комментарию кода.

Сценарий: пользователь настроил split-tunnel правило "direct" для важного домена (локальный роутер/NAS), сеть в момент коннекта была в переходном состоянии → direct-трафик по этому правилу либо не идёт никуда, либо крутится в петле, без единого сообщения об ошибке. Тихая деградация именно того свойства, ради которого фича существует.

Фикс: логировать/показывать в UI, что интерфейс не резолвился и direct-правила могут не работать в этой сессии; в идеале — ретраить резолв или fail fast с понятной ошибкой вместо тихого no-op.

## 2. Жесткие баги в UI приложения

### 2.1. Split tunneling UI доступен в System Proxy mode, хотя runtime его игнорирует

Файлы:
- `teleport/Views/Settings/SplitTunnelingSettingsView.swift:14-22`
- `teleport/ViewModels/AppViewModel.swift:704-706`
- `teleport/Connection/ConnectionBackend.swift:40-42`
- `teleport/Connection/ConnectionBackend.swift:53-55`

UI позволяет включать split tunneling, выбирать profiles, добавлять rules и тестировать match независимо от режима. Но live apply guard-ится `connectionMode == .vpn`, а `SystemProxyConnectionBackend` явно игнорирует `splitTunnelRules`.

Итог: в System Proxy mode пользователь видит рабочие настройки, но они не влияют на реальный proxy behavior. Это жесткий UI bug: интерфейс показывает policy, которую runtime не применяет.

### 2.2. Tester дает слишком уверенный результат для domain rules, хотя runtime зависит от sniffing

Файлы:
- `teleport/Views/Settings/SplitTunnelingSettingsView.swift:88-130`
- `teleport/Parsing/SplitTunnelRuleMatcher.swift:101-146`
- `teleport/Xray/XrayConfigurationWriter.swift:150-155`

Tester показывает deterministic “Matches ...” для домена/IP. В реальном VPN domain routing сработает только когда Xray увидит hostname через sniffing `http`/`tls`. Для QUIC/UDP, ECH, raw IP connects и части приложений rule может не сработать.

UI предупреждает только про geosite/geoip, но не предупреждает про базовое ограничение domain rules. Для пользователя это выглядит как гарантия, которой нет.

### 2.3. Управление profiles может silently менять live routing и делать reconnect без явного UX contract

Файлы:
- `teleport/Views/Settings/SplitTunnelProfilesSheet.swift:13-28`
- `teleport/Views/Settings/SplitTunnelProfilesSheet.swift:69-76`
- `teleport/ViewModels/AppViewModel.swift:663-699`

`Add Profile` создает пустой profile, сразу выбирает его и вызывает live apply. Удаление активного profile silently выбирает первый оставшийся profile и тоже вызывает live apply. В активном VPN это меняет routing policy и может reconnect-ить туннель.

Для сетевой policy это опасный UI contract: CRUD-действие в management sheet фактически применяет новую runtime policy без предупреждения, confirmation или видимого “applied vs edited” состояния.

### 2.4. `Nerd shit` settings синхронно дергает privileged helper с main thread

Файлы:
- `teleport/SettingsView.swift:152-158`
- `teleport/SettingsView.swift:205-216`

`refreshLog()` вызывается из `onAppear`, `onChange` и кнопки, а внутри напрямую делает `PrivilegedHelperClient().readLog(...)`. Если helper недоступен, завис, socket тормозит или лог большой, settings UI будет блокироваться.

Для macOS UI это жесткий responsiveness bug: операции IPC/file IO должны уходить в async task/background, а state обновляться на main actor.

## 3. Баги средней важности

### 3.1. Domain rule semantics в tester и Xray могут расходиться

Файлы:
- `teleport/Parsing/SplitTunnelRuleMatcher.swift:78-98`
- `teleport/Parsing/SplitTunnelRuleMatcher.swift:131-146`
- `teleport/Xray/XrayConfigurationWriter.swift:224-230`

Локальный matcher считает обычный `example.com` как exact/suffix match. Writer кладет `rule.value` в Xray `domain` как есть. Для Xray domain syntax важны явные формы (`domain:`, `full:`, `regexp:`, `geosite:`), и неочевидно, что bare value всегда совпадает с локальной семантикой.

Риск: UI/tester говорит одно, Xray routing делает другое. Особенно неприятно для actions `.direct` и `.block`.

### 3.2. Geodata downloader не валидирует формат dat-файлов

Файл:
- `teleport/Xray/GeodataUpdateService.swift:49-77`

Проверяется только размер `>= 4096` bytes. HTML error page, произвольный binary или geosite вместо geoip попадут в custom storage и затем будут установлены в privileged helper asset directory.

Ошибка проявится позже при старте Xray с плохой диагностикой. Нужна валидация через Xray или хотя бы format sanity-check.

### 3.3. ~~Geodata download блокирует serial operation queue~~ — исправлено, но остался побочный эффект

Файлы:
- `teleport/ViewModels/AppViewModel.swift:779-811`
- `teleport/Xray/GeodataUpdateService.swift:120-157`

Перепроверено на текущем коде: `updateGeodataNow()` теперь диспатчит на отдельную `geodataQueue` (`DispatchQueue(label: "dev.x.teleport.geodata-updates", qos: .utility, attributes: .concurrent)`), а не на `operationQueue`, которая используется для connect/disconnect/reconnect. Так что риск задержки Connect/Disconnect из-за geodata-загрузки, описанный здесь ранее, больше не актуален — оставляю только как низкоприоритетную заметку в 4.6 (семафор всё ещё блокирует поток очереди до 60с и не стримит на диск).

### 3.6-доп. Плановое авто-обновление geodata дёргает reconnect VPN, даже если файл не изменился

Файлы: `teleport/ViewModels/AppViewModel.swift:884-896` (`applyGeodataUpdateResult` → `applyGeodataLiveIfNeeded`), `teleport/Xray/GeodataUpdateService.swift`

`applyGeodataUpdateResult` вызывает `applyGeodataLiveIfNeeded()` (полный reconnect туннеля) на любой успешный `download+store`, без сравнения новых байт со старым файлом. При включённом авто-обновлении (например, "Every hour") идентичный апдейт geosite.dat/geoip.dat всё равно рвёт и поднимает туннель заново.

Сценарий: у подключённого пользователя с почасовым авто-обновлением периодически рвётся соединение на несколько секунд без видимой причины — даже если апстрим-файл не менялся неделями.

Фикс: сравнивать хэш новых байт с уже сохранённым custom-файлом и возвращать "unchanged", чтобы `applyGeodataUpdateResult` пропускал reconnect.

### 3.6-доп2. Двойное побайтовое сравнение больших geodata-файлов на каждый connect/reconnect

Файлы: `teleport/Xray/GeodataUpdateService.swift:90-107` (`resolvedAssetDirectoryURL`), `teleport/Xray/PrivilegedHelperInstaller.swift:55-63` (`installedGeodataMatches`)

Оба метода используют `FileManager.contentsEqual` — полное побайтовое чтение файлов (обычно от нескольких МБ до нескольких десятков МБ). Вызываются один за другим на каждом connect и на каждом live reconnect, который debounce на 0.7с и так планирует при каждой правке split-tunnel правил. В устоявшемся состоянии это два полных прохода по файлам впустую на каждое подключение.

Фикс: сравнивать по размеру+mtime или хранить хэш источника рядом с установленной копией вместо полного побайтового сравнения при каждом вызове.

### 3.6-доп3. `validatedGeodataURL` пропускает URL без хоста

Файл: `teleport/ViewModels/AppViewModel.swift:874-882`

Проверяется только `scheme == http/https` и что `components.url` строится; непустой `host` не требуется (в отличие от аналогичной проверки `validateSubscriptionURL` в этом же файле). `URLComponents(string: "https://")` даёт пустой (не nil) host и валидный `URL`.

Сценарий: пользователь по опечатке вводит `https://` без домена в поле источника geosite/geoip → проходит локальную валидацию → падает уже в сетевом запросе с невнятным `networkFailure` вместо понятного "Enter a valid ... URL." сразу на этапе ввода.

### 3.4. Bulk add rules очищает весь input даже при частичных ошибках

Файл:
- `teleport/Views/Settings/SplitTunnelingSettingsView.swift:255-270`

При paste списка invalid entries собираются в `failures`, но `newRuleValue = ""` ставится и при успехе, и при ошибках. Пользователь теряет исходные invalid строки и вынужден восстанавливать их из error label.

### 3.5. VPN mode может открыть локальные proxy inbounds наружу, если endpoint host не loopback

Файлы:
- `teleport/Xray/XrayConfigurationWriter.swift:158-175`
- `teleport/TeleportModels.swift:103-108`

VPN config поднимает SOCKS/HTTP inbounds на `proxyEndpoint.host`. Сейчас default `127.0.0.1`, но модель не ограничивает host как loopback-only. Если future UI/config import позволит `0.0.0.0` или LAN IP, VPN mode неожиданно станет публичным proxy listener.

### 3.6. ~~`appliedSplitTunnelRules` обновляется до успешного reconnect~~ — уже исправлено в текущем коде

Файлы:
- `teleport/ViewModels/AppViewModel.swift:1000-1032` (`reconnectToSelectedConnection`)
- `teleport/ViewModels/AppViewModel.swift:1044-1063` (`startConnection`)

Перепроверено: в актуальном коде `self?.appliedSplitTunnelRules = activeSplitTunnelRules` стоит **после** `try connectionBackend.reconnect(...)`/`.start(...)`, внутри одного `do`-блока, до `catch`. Если вызов бросает ошибку, до присвоения выполнение не доходит — значит, applied-state больше не обновляется оптимистично. Проблема, описанная здесь ранее, похоже, была устранена в одном из недавних коммитов. Оставшийся реальный риск на этом же поле — data race между потоками, см. **1.7**.

## 4. Баги низкой важности / редкие edge cases

### 4.1. `AppSnapshot.init` может создать snapshot без profiles

Файлы:
- `teleport/TeleportModels.swift:647-672`
- `teleport/ViewModels/AppViewModel.swift:596-609`

Decoder нормализует пустой/missing profiles к Default, но обычный initializer принимает `splitTunnelProfiles: []` и ставит `selectedSplitTunnelProfileID = nil`. Тогда `addSplitTunnelRule` вернет `.success`, но фактически не добавит rule, если selected index не найден.

Сейчас это редкий путь для тестов/будущего кода, но invariant “always at least one profile” не централизован.

### 4.2. `moveSplitTunnelRules` доверяет offsets без bounds validation

Файл:
- `teleport/ViewModels/AppViewModel.swift:641-650`

`let movedRules = offsets.map { rules[$0] }` упадет при некорректном offset. SwiftUI `List.onMove` обычно дает валидные offsets, но при будущих программных вызовах или рассинхроне массива это crash.

### 4.3. Profile rename с пустым значением оставляет UI и модель в разных состояниях

Файлы:
- `teleport/Views/Settings/SplitTunnelProfilesSheet.swift:50-63`
- `teleport/ViewModels/AppViewModel.swift:673-679`

TextField может показывать пустую строку из `editedNamesByID`, а model игнорирует empty rename. После переоткрытия старое имя “магически” возвращается.

### 4.4. Existing VPN parser хрупко смотрит на `columns.last`

Файл:
- `teleport/Xray/XrayTunRouteInspector.swift:33-39`

Парсинг `netstat` ищет `columns.first == "default"` и `columns.last?.hasPrefix("utun")`. Изменение формата, flags/expire/additional columns может дать false negative.

### 4.5. `nextAvailableTunnelInterfaceName()` выбирает имя по race-prone snapshot

Файл:
- `teleport/Xray/XrayTunRouteInspector.swift:69-77`

Код выбирает `utun10...utun199` по текущему `ifconfig -l`, затем передает имя в Xray config. Между выбором и стартом интерфейс может появиться. Редко, но при параллельных VPN/TUN процессах возможен конфликт имени.

### 4.6. Семафорная синхронная загрузка geodata блокирует поток на срок до 60с

Файл: `teleport/Xray/GeodataUpdateService.swift:120-157` (`downloadData`)

`URLSession` + `DispatchSemaphore` вместо `async`/`await` или `downloadTask`. Выполняется на `geodataQueue` (отдельная `.concurrent` очередь), поэтому не блокирует main-поток или очередь коннекта (см. исправление в 3.3) — но при зависшей сети держит поток занятым до полного 60-секундного таймаута, и весь payload буферизуется целиком в памяти перед записью на диск вместо стриминга через `downloadTask`.

### 4.7. Нет ETag/If-Modified-Since для geodata-загрузок

Файл: `teleport/Xray/GeodataUpdateService.swift:121` (`.reloadIgnoringLocalCacheData`)

При почасовом авто-обновлении полностью перекачивается файл (обычно десятки МБ) каждый раз, даже если апстрим не менялся — лишний трафик/батарея, особенно на лимитированных соединениях.

### 4.8. `SplitTunnelProfilesSheet` коммитит rename на каждое нажатие клавиши

Файл: `teleport/Views/Settings/SplitTunnelProfilesSheet.swift:61-63`

`.onChange(of: editedNamesByID[profile.id])` триггерит `renameSplitTunnelProfile` (а значит `schedulePersist()`) на каждый введённый символ, а не по `onSubmit`/потере фокуса. Не ломает корректность, но лишняя работа с диском/UserDefaults при быстром вводе длинного имени.

## 5. Code smell / архитектурные пробелы / отход от стандартов Swift/macOS/iOS разработки

### 5.1. `AppViewModel` не изолирован `@MainActor`

Файлы:
- `teleport/ViewModels/AppViewModel.swift:43-101`
- `teleport/ViewModels/AppViewModel.swift:85-91`

Это большой `ObservableObject` с множеством `@Published`, background queues, Combine timers, callbacks и `Task { @MainActor ... }`. Сам тип не помечен `@MainActor`, поэтому безопасность зависит от дисциплины каждого callback.

Для современного SwiftUI стандартный подход: main-actor isolated view model, background work через services/actors, UI state mutation строго на main actor.

### 5.2. Routing policy размазана между ViewModel, backend, Xray JSON и shell script

Файлы:
- `teleport/ViewModels/AppViewModel.swift:232-238`
- `teleport/Connection/ConnectionBackendFactory.swift:40-79`
- `teleport/Xray/XrayConfigurationWriter.swift:111-238`
- `TeleportPrivilegedHelper/main.swift:587-912`

Одна policy “как работает VPN/split tunnel” реализована в нескольких слоях: Swift state, backend orchestration, `[String: Any]` JSON, root shell commands. Нет единого typed route plan/config plan, который можно валидировать и тестировать.

Из-за этого легко получить расхождения: tester vs Xray, UI mode vs backend ignore, IPv4 routes vs IPv6 leak, DNS exceptions vs privacy model.

### 5.3. Privileged helper исполняет большой shell script строкой

Файлы:
- `TeleportPrivilegedHelper/main.swift:538-567`
- `TeleportPrivilegedHelper/main.swift:587-912`

Root helper собирает большой `/bin/sh -c` script. Даже с quoting/validation это слабее typed privileged operations:
- сложнее тестировать;
- rollback частичный и дублируется;
- route/ifconfig/scutil parsing хрупкий;
- ошибки местами подавляются `|| true`;
- поведение зависит от shell и системных утилит.

Для privileged macOS code лучше прямые `Process` calls с argument arrays или native APIs, плюс явный rollback plan.

### 5.4. Xray config строится как `[String: Any]` с magic strings

Файл:
- `teleport/Xray/XrayConfigurationWriter.swift:62-238`

Большие JSON payloads собираются untyped dictionaries. Compiler не ловит typo в ключах (`autoSystemRoutingTable`, `sockopt.interface`, `domainStrategy`, `xhttpSettings`) и несовместимые значения.

Для core-конфигурации нужен typed `Codable` schema, snapshot tests полного JSON и желательно `xray test -config` validation.

### 5.5. Split-tunnel matcher и Xray rule generation не имеют общего semantic layer

Файлы:
- `teleport/Parsing/SplitTunnelRuleMatcher.swift:101-146`
- `teleport/Xray/XrayConfigurationWriter.swift:218-238`

Комментарий говорит, что tester и routing-rule generation “can never disagree”, но фактически matcher реализует локальную семантику, а writer просто кладет строки в Xray `domain`/`ip`. Geodata вообще не тестируется локально.

Нужен один слой нормализации: user input -> internal semantic rule -> Xray encoding + tester behavior + documented limitations.

### 5.6. Нет интеграционных тестов runtime side effects

Файлы:
- `scripts/verify_core.swift`
- `scripts/verify_split_tunneling.swift`
- `scripts/verify_geodata.swift`

Verification scripts полезны для parser/config/model, но не покрывают главное:
- IPv6 routes/leaks;
- DNS leaks;
- multi-A/AAAA protected endpoint;
- route cleanup после failure;
- existing VPN conflict;
- real helper install/start/stop;
- actual Xray validation of generated configs/geodata.

Для proxy/VPN core это серьезный quality gap.

### 5.7. UI draft state, persisted settings и applied runtime state смешаны в одном `AppViewModel`

Файлы:
- `teleport/ViewModels/AppViewModel.swift:59-99`
- `teleport/ViewModels/AppViewModel.swift:589-721`
- `teleport/ViewModels/AppViewModel.swift:723-865`

`AppViewModel` одновременно хранит persisted settings, editable UI draft, active runtime policy, connection orchestration, geodata update state и health state. Из-за этого UI-действия имеют неочевидные side effects: rename persists on every keystroke, add/delete profile может reconnect-ить VPN, geodata update/reconnect живет рядом с form state.

Лучше разделить settings store, editable drafts, runtime policy и connection orchestrator.

### 5.8. Code signing requirement и Xray hash захардкожены в source

Файлы:
- `teleport/Xray/PrivilegedHelperInstaller.swift:3-5`
- `TeleportPrivilegedHelper/main.swift:142-150`

Team ID requirement и Xray SHA256 сидят прямо в Swift source. Для privileged helper строгий requirement нормален, но он должен быть централизован/генерироваться из build settings или быть явно documented release invariant.

Сейчас смена team, fork, CI signing identity или обновление bundled Xray требует ручных правок в коде. Это хрупко и легко ломает install/runtime authorization.

### 5.9. Privileged helper authorization полагается на console user + code signature, но socket world-writable

Файлы:
- `TeleportPrivilegedHelper/main.swift:87-90`
- `TeleportPrivilegedHelper/main.swift:114-153`

Socket создается `chmod 0666`, затем каждый request проверяет uid console user и code signature. Это лучше, чем просто world-writable socket, но все равно архитектурно шумно: любой процесс может подключаться и триггерить authorization/error path.

Более стандартно ограничить socket permissions/group/owner настолько жестко, насколько возможно, и уже поверх этого делать signature authorization.

### 5.10. `GeodataSourceSettings` — шесть параллельных полей вместо ключа по `GeodataKind`

Файлы: `teleport/TeleportModels.swift:584-631`, `teleport/ViewModels/AppViewModel.swift:829-863`

`geositeURLString/geoipURLString`, `geositeLastUpdatedAt/geoipLastUpdatedAt`, `geositeLastError/geoipLastError` — параллельные поля вместо одной структуры, индексируемой по `GeodataKind`. Отсюда четыре приватных switch-хелпера в `AppViewModel` (`geodataURLString(for:)`, `geodataLastUpdatedAt(for:)`, `setGeodataError`, `setGeodataLastUpdatedAt`) плюс copy-paste пара `setGeositeURL`/`setGeoipURL`, а `GeodataSettingsView.statusText` дублирует ту же диспетчеризацию тернарными `kind == .geosite ? ... : ...`. Три независимых ручных диспетчера на один enum — при добавлении нового атрибута (например, `lastETag`, см. 4.7) легко обновить не все места. Структура `struct GeodataSourceEntry { urlString, lastUpdatedAt, lastError }` + `subscript(kind:)` убирает все четыре хелпера разом.

Заодно `GeodataSourceSettings` вручную пишет `CodingKeys`+`init(from:)` для семи всех-опциональных полей, хотя синтезированный `Codable` компилятора делает то же самое для optional-полей без ручного кода (в отличие от `SplitTunnelRule`/`SplitTunnelProfile`/`AppSnapshot`, где ручной `init(from:)` оправдан миграционной логикой legacy-полей).

### 5.11. Инбаунды `socks-in`/`http-in` продублированы между `makePayload` и `makeTunnelPayload`

Файл: `teleport/Xray/XrayConfigurationWriter.swift:69-84, 162-175`

Идентичные словари для socks/http inbound скопированы буквально, с комментарием "same as System Proxy mode's inbounds" — автор сам осознаёт дублирование, но не вынес общий `makeProxyInbounds()`. Правка одного режима (auth, sniffing) не затронет второй, и ничего не помешает им разойтись.

### 5.12. Политика "только включённые правила" применяется дважды + дублирующаяся ветка switch

Файлы: `teleport/ViewModels/AppViewModel.swift:238-239` (`activeSplitTunnelRules`), `teleport/Xray/XrayConfigurationWriter.swift:113-115, 224-235` (`makeTunnelPayload`, `makeSplitTunnelRoutingRule`)

`AppViewModel.activeSplitTunnelRules` уже фильтрует `isEnabled` перед передачей правил в backend; `makeTunnelPayload` фильтрует `isEnabled` второй раз. Два независимых места, отвечающих за один инвариант — источник рассинхрона, если один из фильтров позже поменяют (например, ради "preview disabled rule"). Там же `makeSplitTunnelRoutingRule`'s switch имеет одинаковые по действию ветки `.domain`/`.geosite` (`routingRule["domain"] = [rule.value]`) — их можно схлопнуть в `case .domain, .geosite:`.

### 5.13. HTTP-загрузчик geodata — копипаста существующего клиента подписок

Файлы: `teleport/Xray/GeodataUpdateService.swift:120-157`, `teleport/Subscriptions/SubscriptionServices.swift` (`SubscriptionClient.fetchCandidateLinks`, ~строки 99-133)

Практически дословная копия синхронного `URLSession`+`DispatchSemaphore` загрузчика (тот же `.reloadIgnoringLocalCacheData`, `.ephemeral`-сессия, та же обработка ошибок в 4 шага) — отличается только имя error enum. Фикс в одном месте (retry, редиректы, обход собственного прокси при скачивании geodata) не долетит до второго.

### 5.14. Путь `Application Support/teleport` пересобирается инлайн в семи местах

Файл: `teleport/Xray/GeodataUpdateService.swift:163-166` (`applicationSupportDirectoryURL`)

Та же конструкция уже есть в `SettingsView.swift`, `ConfigurationStore`, `XrayRuntimeManager`, `XrayTunSessionState`, `SystemProxyService`, `XrayConfigurationWriter`. Семь независимых копий одного базового пути — при будущем изменении (например, sandbox container path) легко забыть один из них, и geodata тихо перестанет находиться там, где её ищет установщик хелпера.

### 5.15. `SplitTunnelingSettingsView.addRule()` дублирует bulk-путь отдельной веткой для одного правила

Файл: `teleport/Views/Settings/SplitTunnelingSettingsView.swift` (~строка 239, `addRule()`)

Специальная ветка для `candidates.count <= 1`, хотя единственный trim-нутый кандидат, пропущенный через общий bulk-цикл, дал бы тот же результат (`SplitTunnelRuleClassifier.classify` и так делает `trim`). Два параллельных success/error пути уже разошлись в формулировках ошибок и должны редактироваться синхронно вручную.

## Короткий приоритет исправлений

1. Закрыть IPv6 leak: полноценно туннелировать IPv6 или явно блокировать/disable IPv6 в VPN mode с предупреждением.
2. Пересмотреть DNS routing: не выводить публичные DNS наружу silently; сделать контролируемый DNS path или явный режим с warning.
3. Защитить proxy endpoint по resolved IP set, включая IPv6/multi-address, и синхронизировать DNS/route behavior с Xray.
4. Развести System Proxy и VPN state: VPN mode не должен восстанавливать чужой system proxy поверх себя.
5. Скрыть/disable split tunneling в System Proxy mode или явно показать “VPN only”.
6. Перенести `AppViewModel` на `@MainActor`, вынести services/actors и убрать blocking IPC/network с main/connection queue; отдельно — снять data race на `appliedSplitTunnelRules` (1.7).
7. Обработать случай, когда физический интерфейс не резолвится: split-tunnel "direct"-правила не должны молча зацикливаться в TUN (1.8).
8. Ввести typed route/config policy layer и integration tests для routes, DNS, helper start/stop и Xray config validation.

---

### Примечание к этому проходу ревью

Этот файл — слияние трёх проходов:
- (а) более ранний полный ручной аудит core-логики (разделы 1.1-1.6, 2, большая
  часть 3-5 — IPv6/DNS leaks, System Proxy interaction и т.д.);
- (б) второй проход по ветке `nrydanov/split-tunneling` (новые 1.7, 1.8,
  исправления в 3.3/3.6, новые 4.6-4.8, 5.10-5.15);
- (в) **третий проход (перезапуск погибших агентов на Opus)** — все 5 упавших
  ранее углов (line-by-line, removed-behavior, cross-file tracer, altitude,
  conventions) отработали полностью. Их находки — раздел «Дополнительные
  находки (3-й проход)» ниже, с пометкой ✅ verified / ❌ refuted по результатам
  ручной проверки.

---

## Дополнительные находки (3-й проход, агенты на Opus)

Каждая находка проверена вручную по коду/сборке. Формат: ✅ подтверждено /
❌ опровергнуто / ⚠️ подтверждено с оговоркой.

### НОВОЕ-1 ✅ [CORE, высокий] Доменные правила эмитятся без префикса `domain:` — Xray делает substring-match, тестер делает suffix-match

Файлы: `teleport/Xray/XrayConfigurationWriter.swift:225-226`,
`teleport/Parsing/SplitTunnelRuleMatcher.swift:131-146`,
`openspec/changes/add-split-tunneling/design.md`

`makeSplitTunnelRoutingRule` для доменного правила кладёт `routingRule["domain"] =
[rule.value]`, где `rule.value` — «голый» домен вроде `example.com` без префикса.
В синтаксисе Xray значение в массиве `domain` без префикса — это **plain
(substring) matcher**: оно матчит любой хост, *содержащий* эту подстроку. То есть
правило `example.com` в Xray совпадёт не только с `example.com`/`www.example.com`,
но и с `myexample.com`, и с `example.com.evil.net`.

Локальный тестер (`domainRuleMatches`) при этом делает строгий suffix-match:
`candidate == value || candidate.hasSuffix("." + value)` — который эти лишние
хосты **не** матчит. Итог:
- прямое нарушение spec-требования "Tester result stays consistent with generated
  routing behavior" (`spec.md`): тестер и Xray дают разные ответы для голых доменов;
- нарушение `design.md` (Decision "Domain matching uses Xray's `domain` field with
  automatic subdomain inclusion" — подразумевался `domain:`-префикс);
- security-грань: правило с action `.block`/`.direct` на `example.com` неожиданно
  зацепит `example.com.attacker.net` (для `.direct` — увод трафика мимо туннеля к
  постороннему хосту).

Фикс: генерировать `["domain:" + rule.value]` (и `full:` для exact-правил),
синхронно с семантикой тестера. Заодно поправить `scripts/verify_split_tunneling.swift:~190`,
который хардкодит текущее (неверное) поведение `domains == [rule.value]`.

### НОВОЕ-2 ✅ [UI/средний] Многомегабайтная запись geodata на диск выполняется на main actor — фриз UI

Файл: `teleport/ViewModels/AppViewModel.swift:795-803`

В `updateGeodataNow` загрузка идёт на фоновой `geodataQueue`, но success-путь
прыгает в `Task { @MainActor }` и там вызывает `try service.store(data, for: kind)`.
`store` внутри делает синхронный `data.write(to:options:.atomic)` для файла в
десятки МБ (geoip.dat ~19 МБ, geosite.dat ~10 МБ в текущем бандле) — то есть
тяжёлая дисковая запись происходит на главном потоке, подвешивая меню/настройки
на время записи (заметно на медленных дисках/при авто-обновлении). Дополнительно
эта запись на MainActor не синхронизирована с connect-путём на `operationQueue`,
который читает/копирует те же файлы через `resolvedAssetDirectoryURL`.

Фикс: держать `store()` на фоновой очереди, прыгать на MainActor только чтобы
опубликовать финальный результат.

### НОВОЕ-3 ✅ [средний/низкий] Пользовательские split-tunnel правила подставляются ПОСЛЕ захардкоженных block-правил

Файл: `teleport/Xray/XrayConfigurationWriter.swift:193-213`

Массив routing rules собирается как `[udp-block 135,137-139,5353] + [ip 224.0.0.0/3
block] + splitTunnelRoutingRules + [proxy tcp,udp]`. По first-match-wins два
block-правила стоят **раньше** пользовательских. Если пользователь добавит правило
(ip/geoip/domain) с action `.proxy`/`.direct`, чья цель попадает в `224.0.0.0/3`
или UDP-порты 135/137-139/5353 — его правило никогда не применится, трафик молча
дропнется block-правилом. Противоречит spec-требованию про first-match в
пользовательском порядке. Узкий, но реальный кейс (multicast/mDNS/NetBIOS).

Фикс: либо ставить пользовательские правила перед служебными block-правилами,
либо явно документировать, что служебные block-правила имеют приоритет.

### НОВОЕ-4 ✅ [низкий, редкий] `rawAuthorityHost` возвращает сырой (percent-encoded) хост в обход декодирования

Файл: `teleport/Parsing/ConnectionLinkParser.swift:162-195`

`parseBase` теперь предпочитает `rawAuthorityHost(from: rawLink) ?? parsedHost`
вместо `components.host`. `rawAuthorityHost` вырезает подстроку authority из сырой
ссылки без percent-декодирования. Для ссылки с percent-кодированным хостом
(`vless://uuid@ex%61mple.com:443?...`) старый код давал `example.com`, новый вернёт
литерал `ex%61mple.com`, который уйдёт в Xray outbound и в цель protected-route →
DNS/connect fail. Замечание: изменение вне core split-tunneling, но входит в diff
ветки. Вероятно, `rawAuthorityHost` добавлен ради сохранения регистра хоста — тогда
достаточно сохранять регистр, но всё равно применять `removingPercentEncoding`.

### НОВОЕ-5 ⚠️ [низкий, robustness] Один битый legacy-правило рушит декодирование ВСЕГО `AppSnapshot`

Файл: `teleport/TeleportModels.swift:709-717, 549-556`

Legacy-миграция делает `legacyContainer.decodeIfPresent([SplitTunnelRule].self, ...)`.
`SplitTunnelRule.init(from:)` жёстко декодирует `id`/`value`/`kind` (только `action`
и `isEnabled` через `decodeIfPresent`). Если хотя бы один элемент массива не
декодируется, бросок пробивает `decodeIfPresent` и рушит декод всего `AppSnapshot` —
теряются ВСЕ настройки (connections, subscriptions, ports), а не только split-tunnel.

Оговорка (проверено git-археологией): `kind` присутствует в схеме с самого первого
коммита flat-списка (`3a1c6db`), поэтому через нормальный путь апгрейда это
**недостижимо** — только при ручной правке/повреждении JSON. Поэтому severity низкая.
Тем не менее принцип «одно битое правило не должно обнулять все настройки» стоит
заложить: декодировать rules по одному через `try?` и отбрасывать битые.

### НОВОЕ-6 ⚠️ [altitude/средний] Несогласованный lookup bundled-geodata + новая жёсткая зависимость VPN от geodata

Файлы: `teleport/Xray/GeodataUpdateService.swift:114-118`,
`teleport/Xray/XrayRuntimeManager.swift:140-141`,
`teleport/Xray/PrivilegedHelperInstaller.swift:15-35`

Два разных предположения о раскладке ассетов в бандле:
- `XrayRuntimeManager.assetDirectoryURL()` ищет `bundle.url(forResource: "xray-assets",
  withExtension: nil)` — трактует .dat как содержимое подпапки `xray-assets/`;
- новый `GeodataUpdateService.resolvedSourceURL` ищет `bundle.url(forResource: "geosite",
  withExtension: "dat")` — трактует их как ресурсы в корне Resources.

**Проверено на реальном билде:** проект использует `PBXFileSystemSynchronizedRootGroup`
(Xcode 16), который схлопывает `Resources/xray-assets/*.dat` в корень
`Contents/Resources/`. Поэтому сейчас работает именно top-level lookup нового кода
(файлы находятся), а `forResource:"xray-assets"` возвращает nil — но это безвредно,
т.к. System Proxy конфиг не использует geodata. **→ тревога агентов «VPN вообще не
коннектится» ОПРОВЕРГНУТА** для текущего билда.

Остаётся реальная хрупкость (почему ⚠️, а не ❌):
1. два lookup'а противоречат друг другу в предположениях о layout — если бандлинг
   когда-нибудь переведут на настоящий folder reference (сохраняющий подпапку),
   новый top-level lookup сломается и **все** VPN-подключения упадут;
2. `ensureInstalled` теперь **безусловно** резолвит bundled geodata на каждый
   VPN-connect (даже при выключенном split-tunneling и нуле правил) — новая жёсткая
   зависимость: битый/stripped .dat в бандле уронит ранее рабочий VPN-connect с
   `installFailed("...bundled geodata is missing")`.

Фикс: один общий источник правды о расположении geodata-ассетов (тот же метод, что
использует `XrayRuntimeManager`), и не делать bundled-geodata обязательным, когда
split-tunneling выключен.

### НОВОЕ-7 ✅ [altitude/низкий] `domainStrategy` захардкожен `"AsIs"` независимо от наличия доменных/geosite-правил

Файл: `teleport/Xray/XrayConfigurationWriter.swift:192`

В TUN-конфиге `"domainStrategy": "AsIs"` зашит константой. При `AsIs` доменные и
geosite-правила матчатся только по сниффленному hostname (http/tls), но не по
резолвленному IP. Это усиливает уже описанное ограничение 2.2 (тестер слишком
уверен): для QUIC/UDP/ECH/raw-IP доменные правила могут не сработать, хотя UI
показывает совпадение. Более глубокий фикс — выбирать `IPIfNonMatch`/`IPOnDemand`,
когда в наборе есть доменные/geosite-правила, или явно документировать ограничение.

### НОВОЕ-8 ✅ [altitude/низкий] `AppSnapshot` не имеет поля версии схемы — миграция накапливается ad-hoc

Файл: `teleport/TeleportModels.swift:690-728`

Миграция сделана через побочный `LegacyCodingKeys`-контейнер + `decodeIfPresent`
с дефолтами на каждое поле. Нет `schemaVersion`, поэтому нельзя понять, из какого
поколения снапшот, и нельзя чисто отвергнуть файл от более новой версии. Каждое
будущее изменение персистентной модели будет добавлять ещё одну inline-ветку
совместимости. Фикс: явный `schemaVersion` + версионированные шаги миграции.

### НОВОЕ-9 ✅ [altitude/низкий] Формат `geosite:`/`geoip:` stringly-typed, префикс закодирован дважды (в `kind` и внутри `value`)

Файлы: `teleport/Parsing/SplitTunnelRuleMatcher.swift:21-31`,
`teleport/Xray/XrayConfigurationWriter.swift:224-235`

Классификатор хранит полную строку `"geosite:google"` в `value` И одновременно
ставит `kind = .geosite`. Writer заново ветвится по `kind`, чтобы положить `value`
в `domain` или `ip`. Матчер спец-кейсит оба kind, чтобы их пропустить. Префикс
живёт в двух местах — при рассинхроне `value`/`kind` получится молча неверный
роутинг. Более глубокий фикс: парсить один раз в типизированный payload (enum с
ассоциированными category/domain/cidr), чтобы `kind` и `value` не могли
противоречить.

### Опровергнутые тревоги (проверены и отклонены)

- ❌ **«GeodataUpdateService не находит bundled .dat → VPN не коннектится для всех»**
  (Angle C): опровергнуто — synchronized root group схлопывает файлы в корень
  Resources, top-level lookup работает. См. НОВОЕ-6 (осталась только хрупкость).
- ❌ **«Legacy-правило без `kind` рушит все настройки на реальном апгрейде»**
  (Angle B): `kind` есть с первого коммита схемы; недостижимо через нормальный
  путь. Понижено до robustness-заметки НОВОЕ-5.

### Обновление сводки

| Группа | Было (проходы а+б) | +3-й проход | Итого значимых |
|---|---|---|---|
| Core-логика (прокси) | 8 | +1 (НОВОЕ-1) | 9 |
| UI | 4 | — | 4 |
| Средняя важность | 9 | +2 (НОВОЕ-2, НОВОЕ-3) | 11 |
| Низкая важность | 8 | +2 (НОВОЕ-4, НОВОЕ-5) | 10 |
| Code-smell/архитектура | 15 | +4 (НОВОЕ-6..9) | 19 |

Топ-приоритет после 3-го прохода — **НОВОЕ-1** (голые домены → substring-match в
Xray расходится с suffix-match тестера, с security-гранью для block/direct правил):
это единственная новая находка уровня core-корректности, и она подтверждена против
кода, design.md и verify-скрипта.
