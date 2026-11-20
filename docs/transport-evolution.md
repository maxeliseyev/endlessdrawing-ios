# Эволюция транспорта: план для iPad

## WS v6 — 20.11.2026

Реализован [нормативный v6](../../endless-drawing-backend/docs/protocol-v6-compact.md): preference v6→v5→v4→v3→v2→JSON v1. Профиль неизменен в течение соединения. `WS_COMPACT_ENABLED=false` откатывает новые соединения к v5, не требуя старого backend image или миграции локального журнала.

- Server `path` (2…4000 integer элементов) превращается в 1…2000 `WorldPoint`, накопление в integer space, деление на 16. Preflight запрещает даже целочисленные float-теги внутри path, unsafe integer, duplicate keys и прежние опасные структуры; лимит клиентских массивов остаётся 2000.
- Snapshot/fetch, live и create ack используют один decoder. Chunk budget — 8192 **точек**, не элементов path. World/span/style/author guards остаются обязательными; синтетический snapshot fixture намеренно выходит за world/span и не разрешает ослабить domain guards.
- Create/journal/retry сохраняют исходные float64. Только v6 ack сравнивается с каждой независимо округлённой исходной точкой (ties away from zero), остальные поля совпадают точно; v5 и ниже по-прежнему требуют полного равенства. Confirmed принимает серверную геометрию, undo/compensating delete прежние.
- Pinned backend `ws-v6` corpus и SHA-256 скопированы без изменения содержимого, с префиксом имён `ws-v6.` для плоского Xcode resource bundle; проверяются Rust и TS bytes.

Проверки: Debug и Release Simulator iOS 27.0 — suite из 176 тестов (opt-in network/performance gates пропущены), включая compact fixtures/guards, journal ack и существующие transport/world tests. Отдельно `LocalBackendTests` с пустой изолированной PostgreSQL DB прошёл на v6 и при `WS_COMPACT_ENABLED=false` на v5: четыре кисти с координатами вне сетки 1/16, legacy JSON observer, ownership, idempotent retry и undo. Ожидаемый профиль проверялся через `TEST_RUNNER_ENDLESS_EXPECT_WS_VERSION=6` / `5`, URL — `TEST_RUNNER_ENDLESS_LOCAL_BACKEND_WS=ws://127.0.0.1:3001/ws`. Opt-in production gates не запускались. Физический iPad и production не проверялись и не выкладывались.

Статус: T1 уже подключён к общему Canvas в [M2.3](progress/m2-shared-canvas.md): WorldSession, scene, journal и четыре кисти, поверх M2.1/M2.2. Isolated backend/Postgres mutations и native read-only published WSS проверены. **T2/T3 подключены 18.11.2026** по опубликованному backend M3 (`5ac7ddf`): клиент предлагает `endless-drawing.msgpack.v4`, `…v3`, `…v2`, `endless-drawing.json.v1`. v4 — `visible_bounds` (видимое ∩ подписка) в каждой подписке; v3+ — cached subscribe внутри соединения после завершённого snapshot (`ManifestLoader`: manifest → reuse из сцены → fetch недостающих batch ≤1000, stop-and-wait), `snapshot.fallback` busy/scene_limit → full через 1 с, нарушение контракта → reconnect + full. Pinned fixtures `ws-v3`/`ws-v4` (префикс файлов), read-only production smoke выбрал v4. Physical iPad acceptance остаётся.

## 1. Источники и версии

- [Backend MessagePack v2](../../endless-drawing-backend/docs/protocol-v2-msgpack.md) — единственный нормативный профиль реализованного M1.
- [Frontend v2 reference](../../endless-drawing-frontend/docs/protocol-v2-msgpack.md) — ссылка/история проектирования, не второй контракт.
- [Transport design](../../endless-drawing-frontend/docs/transport-v2-design.md) — этапы manifest/cache и visible-first.
- [Backend v1](../../endless-drawing-backend/docs/protocol.md) — текущий работающий wire-контракт.

Backend и frontend M1 реализованы, нормативная спецификация перенесена в backend; к финальной проверке в соседних репозиториях также появился последующий v3/manifest. Native read-only production WSS подтверждён позже в M2.3, не выдаётся за physical device acceptance. Нативные зависимости, pinned corpus и выполненные проверки — [отчёт M2.2](progress/m2-msgpack-transport.md). В frontend появился offer v3, но iPad не предлагает его до согласованного подключения следующего wire.

Исторический снимок первоначальных frontend draft, прочитанных до реализации M1: HEAD `fdcfdf0`, оба документа тогда были untracked и не входили в этот commit. Эти хеши не являются текущей нормативной спецификацией:

| Файл frontend docs | SHA256 |
| --- | --- |
| `protocol-v2-msgpack.md` | `4e0dc7ea7486c7d53cf9e570b6779cf465f0c0b848f5362f03e34de995095a51` |
| `transport-v2-design.md` | `b7697a54d193814b3afaa6b3f68439e9f5cd9be40d9430df812260727d223855` |

Ниже T1/T2/T3 соответствуют транспортным M1/M2/M3 из frontend design. Это **не** нативные M1 (Pencil/Metal), M2 (общий мир), M3 (инструменты) из основного плана.

## 2. Три отдельных изменения

| Этап | Что принимаем для iPad | Что не считаем решённым |
| --- | --- | --- |
| T1 — MessagePack v2 | Один negotiated codec для всех application messages, Double geometry, прежние snapshot semantics | Повторная передача полного snapshot ещё остаётся |
| T2 — manifest/cache | Авторитетный manifest новой области, geometry fetch только отсутствующих UUID | Это не «послать только новую полосу bounds» и не event cursor по seq |
| T3 — visible-first | Видимая geometry раньше prefetch в рамках одного согласованного snapshot | Меняется порядок доставки, но не порядок наложения по seq |

T1 реализуем/проверяем первым. T2/T3 требуют отдельного согласованного wire-контракта следующей версии: в опубликованный v2 нельзя молча добавить token/fetch/visible_bounds. Номер/имя следующего профиля и точные новые messages здесь не изобретаем.

Независимо от rollout других клиентов, native acceptance ещё требует deployed backend negotiation и mixed-client smoke. Профиль iPad нельзя считать проверенным на production только от одного codec/loopback теста. T1 и shared-world UI активны в M2.3; реальные mixed-profile mutations проверены на отдельной dev БД, public WSS — только read-only.

## 3. Нативная граница кодека

```text
URLSessionWebSocketTask / selected subprotocol
    → message type + profile byte limit
    → bounded codec / structural validation
    → typed application guards
    → WorldSession / SceneStore / OperationJournal
    → RenderSnapshot / Metal
```

### Negotiation до hello

Negotiated mode предлагает строго в таком порядке:

1. `endless-drawing.msgpack.v2`
2. `endless-drawing.json.v1`

В нативном API доступны `webSocketTask(with:protocols:)` и delegate `urlSession(_:webSocketTask:didOpenWithProtocol:)` (с iOS 13, deployment target не повышаем). Выбранный профиль проверяется в callback **до отправки hello**, codec закрепляется за connection generation до закрытия socket.

- Выбранный v2 → только Binary MessagePack, hello ack version 2.
- Выбранный explicit v1 → только Text JSON, hello ack version 1.
- Пустой/непредложенный профиль при наличии offers → ошибка соединения, не угадывать codec по bytes.
- Не открывать второй socket и не повторять автоматически handshake без subprotocol ради обхода отказа.
- Legacy JSON без offers допустим только как заранее выбранный deployment/dev mode до готовности dual-profile сервера; ожидается отсутствие selected protocol. Это не fallback после неудачного negotiated handshake.
- Origin остаётся обязательным. Для API с URL+protocols можно задать его на отдельной ephemeral URLSession configuration для этого environment; вариант URLRequest должен также доказать корректную отправку offers. Проверка объекта URLRequest не заменяет реальный Upgrade test.
- Reconnect повторяет ту же policy/offers; между соединениями сервер может выбрать другой разрешённый профиль, внутри одного socket codec не меняется.
- Штатный rollback — сервер выбирает explicit JSON на новых соединениях, сохраняя dual-profile поддержку. Откат к backend без negotiation нельзя делать, пока остаются установленные negotiated-native clients: они не должны обходить несовместимость auto-legacy retry.

Нужна одна последовательная receive/decode loop вне main thread. Нельзя независимо декодировать messages в нескольких Tasks, переставляя snapshot/ack/delete. Delegate callbacks и async результаты проверяют generation. Очереди receive/send ограничены по count и bytes; при overflow resnapshot/reconnect, а не тихая потеря событий.

### Profile-specific limits

Краткая памятка, нормативные значения — в исходной спецификации:

| Профиль | Message type | Server payload | Client payload |
| --- | --- | ---: | ---: |
| Legacy/explicit JSON v1 | Text | Текущий нативный лимит 4 MiB, без скрытого ужесточения при refactor | 128 KiB |
| MessagePack v2 | Binary | 256 KiB | 128 KiB |

Для v2: target chunk 64 KiB, ≤1000 strokes и ≤8192 points/chunk; structural depth ≤8, array length ≤2000, map pairs ≤16, string ≤256 UTF-8 bytes, tree nodes ≤65536. Domain guards и scene budgets применяются дополнительно. До decode настроить receive cap; после выбора профиля он должен соответствовать этому профилю.

Проверять headers/длины/доступные bytes до allocations, exact single object и отсутствие хвоста. Reject duplicate/non-string/опасные map keys, bin/ext/timestamp/nil и типы вне профиля; optional fields отсутствуют. Не допускать lossy float32 output, unsafe integer coercion и подмену boolean числом. Координаты/width/opacity/spawn/bounds сохраняют Double; seq остаётся безопасным integer, не курсором событий. Проверки относятся и к полям, которые application model иначе проигнорировала бы.

Подключён `msgpack-swift` exact 2.0.6, product DMMessagePack, с Codable mapping и обязательным bounded preflight. Пакет losslessly сокращает некоторые Double до float32, поэтому только trusted encoder output ограниченно разворачивается обратно в float64; входящий float32 запрещён. Детали аудита/адаптера и byte/bit tests — [M2.2](progress/m2-msgpack-transport.md). Самописного encoder и MessagePack → JSON text → JSONDecoder нет.

Ошибки: wrong Text/Binary → Close 1003, oversize → 1009, malformed/budget/trailing bytes → 1007. Не повторять неограниченный decode для извлечения request_id. Application compression, permessage-deflate и streaming незавершённых штрихов в этот этап не входят.

## 4. Что сохраняется из M2.1

- `StrokePayload`, UUID, Double points, normalization, ownership и semantic idempotency — прежние.
- `ClientMessage`/`ServerMessage` остаются логическими сообщениями; JSON helper methods выносятся за codec boundary. Version ack проверяется относительно выбранного профиля, а не общей константы 1.
- `WireLimits.maximumServerBytes = 4 MiB` не становится общим лимитом v2: нужен профильный receive/decode budget и point budget на chunk.
- Journal хранит semantic immutable payload, не готовый frame выбранного codec. После потери JSON ack допустим retry через MessagePack с тем же UUID/числами; request_id новый, второй undo entry не создаётся.
- JSON на диске journal не надо менять на MessagePack ради сети. Offline enqueue сохраняет консервативную JSON-проверку размера, send дополнительно проверяет фактический encoding/envelope.
- Keychain identity и journal location не зависят от выбранного subprotocol. Префиксы `v1` в `identityAccount`, storage path и journal schema — **версии хранения**, не wire version. При переходе к v2 их не менять: это потеряло бы доступ к прежнему owner/outbox.
- Snapshot token, canonical scene cache и pending/outbox — разные сущности. Token никогда не сохраняется в journal и не даёт mutation rights.
- Геометрия, spray seed, Metal buffers и opacity-per-stroke не изменяются из-за бинарного формата. Сетевой источник — `StrokePayload.points` в Double, не локальные Float mesh/circle buffers Metal. Predictions не отправляются ни в одном профиле.

## 5. Manifest и надёжные удаления

Для T2 клиент получает полный bounded manifest UUID новой области и server-owned token согласованного снимка. Это лёгкая сверка состава области плюс только недостающая тяжёлая geometry, а не исключительно прямоугольная разница bounds.

Инварианты будущего SceneStore:

1. Старый display/cache не выбрасывается на subscribe; manifest собирается отдельно по subscription identity и generation.
2. Cache hit возможен только для полной immutable server record нужной identity/current connection. Pending draft без server seq/own не является canonical cache hit.
3. На время staging записи, заимствованные из cache, pin сильными ссылками; eviction не может превратить объявленный hit в отсутствующую geometry до end.
4. Geometry requests ограничены и относятся только к UUID из текущего manifest/token. Не запрашивать произвольный ID или own ack вне manifest через этот token.
5. Удалённое в overlap обнаруживается отсутствием в полном manifest при end, даже если прежний delete event был пропущен. Известные tombstones/optimistic hide имеют приоритет уже до end.
6. После snapshot boundary серверные create/delete/hide буферизуются и идут после end. Удаление после границы не теряется и не маскируется исходным seq.
7. Own acks, pending и compensation delete живут отдельно от authoritative membership; snapshot absence не означает глобальное удаление и не очищает undo.
8. Reconnect/new subscribe/resync/timeout отменяют token/fetch/staging. Late responses старой identity не меняют текущую сцену. Reconnect начинает свежую синхронизацию, не resume по last_seq.

Полный manifest 20000 строковых UUID сам занимает примерно 742 KiB до служебных полей, поэтому он тоже chunked и bounded; zero geometry bytes ≠ zero traffic. При truncation/превышении caps нельзя выдать частичное состояние за complete manifest. Нужны нормативные limit/fallback outcomes, а не новые локально придуманные messages.

Server-side snapshot retention, deadline, pool/slow-client limits и fairness missing reads к create/delete/heartbeat — часть общего контракта, не оптимизация исключительно iPad. Они должны быть проверены до включения T2.

## 6. Видимое раньше запаса и progressive display

Подписка по-прежнему включает prefetch: до 3× по каждой оси, то есть до 9 экранов по площади при отсутствии span clamp. Отдельный visible_bounds — предложение для следующего контракта, не допустимое новое поле в сегодняшнем v2 subscribe.

- Не делать маленький полный subscribe, затем большой полный subscribe: это повторная загрузка, не visible-first.
- Geometry, пересекающая visible bounds, передаётся и готовится раньше prefetch в том же snapshot. CPU geometry queue и GPU uploads также учитывают видимость, иначе серверный приоритет потеряется в клиентской очереди.
- Порядок доставки не равен порядку наложения: renderer всегда сортирует по server seq. Поздняя старая вставка инвалидирует затронутые tiles; не поднимает штрих поверх новых.
- Для T1 сохраняется серверный порядок chunks по seq. Visible-first нельзя объявлять выполненным только потому, что начат progressive display.

**Изменение прежнего нативного плана:** staging начинает показывать валидные server strokes по мере готовности geometry, не ждёт snapshot.end. Display set — bounded union stale/confirmed и staging с дедупликацией UUID, исключая hidden/tombstones; это ещё не новая authoritative область.

Только end заменяет authoritative membership и удаляет отсутствующее. Empty/fully-cached snapshot должен завершать loading и deadline даже если render set не изменился. При отмене уже показанные валидные records можно оставить как bounded stale cache до следующей сверки, но не помечать область complete; pins старого staging освобождаются. Частичный/оборванный snapshot не завершает resync и не доказывает удаление.

Для холодного cache manifest→missing добавляет WAN RTT. Вариант первого visible push без этого round trip требует benchmark и отдельной фиксации wire; до этого его не реализуем как необъявленное расширение.

## 7. Карта изменений iPad-кода

| Компонент | Следующий шаг |
| --- | --- |
| Новый `TransportProfile` / `SessionCodec` | Names, selected profile/version, typed Text/Binary, profile budgets и encode/decode |
| `Networking/WireProtocol.swift` | Отделить JSON entry helpers от application validation; profile-aware hello/version и chunk guards |
| `Networking/DrawingEnvironment.swift` | Сохранить identity scope; deployment policy/codec не добавлять в owner namespace |
| Будущий `WebSocketTransport` | Delegate negotiation, explicit Origin, одна bounded receive loop и serial send, generation guard |
| Будущий `SceneStore` | Progressive staging в T1; manifest/missing/pinning только после нормативного T2 wire |
| `Persistence/OperationJournal.swift` | Не мигрировать storage из-за MessagePack; sender кодирует semantic operation выбранным codec |
| `Rendering/*` / geometry scheduler | Без изменения brush geometry; получать deduplicated render deltas, затем visible-first scheduling |
| `Endless DrawingTests/Fixtures/` | Неизменяемая копия общего wire corpus с source revision/SHA256, отдельная от round geometry fixtures |

## 8. Gates и порядок работ

1. Зафиксировать общий backend контракт и межъязыковой corpus. Нативный клиент читает backend/JS fixtures, его client-message output читается другими сторонами; self-round-trip одной Swift-библиотеки недостаточен.
2. Выбрать/проверить Swift codec, bounded preflight и positive/negative fixtures без включения сетевого UI.
3. Выпустить dual-profile backend раньше negotiated clients. Доказать coexistence legacy JSON / explicit JSON / MessagePack, Origin и ack version. Пустой selected profile не лечить auto-legacy retry.
4. Подключить native transport/session, journal и progressive scene; до shared-world release добавить все четыре renderer-формы.
5. На отдельной следующей версии закрыть manifest/token/cancellation/limit wire, затем visible-first и cold-cache benchmark. Не добавлять schema placeholders в текущие DTO заранее.
6. Сравнить bytes, handshake, first chunk, decode/validate, geometry prep, **first visible paint**, end и memory p50/p95 на одинаковом корпусе/world bounds/camera path. warm/cache/pan/reconnect/empty — отдельные сценарии; провести device/WAN acceptance.

Приёмка дополнительно требует: malformed lengths/depth/node/duplicate-key tests без частичного state update; cross-profile unknown-ack retry без смены identity/UUID; delete/hide в overlap, interrupted staging, missing после eviction и own ack вне области; late old-subscription frames; отсутствие повторного затемнения и resurrection. Подробности — [validation.md](validation.md).

Статус реализации фиксируется отдельно: codec/standalone transport T1 и новые tests — [M2.2](progress/m2-msgpack-transport.md); WorldSession/общий Canvas подключены в [M2.3](progress/m2-shared-canvas.md). Manifest T2 и visible-first T3 не объявляются выполненными от одного бинарного формата.
