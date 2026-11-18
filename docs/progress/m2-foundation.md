# M2.1 — протокол, identity и durable operations

Этот исторический отчёт фиксирует JSON v1 foundation и его 57 тестов. Следующий срез уже реализован отдельно: [M2.2 — MessagePack v2 / JSON v1 codec и standalone transport](m2-msgpack-transport.md). На момент M2.1 Canvas ещё не был подключён; актуальное подключение — [M2.3](m2-shared-canvas.md). Будущие manifest/visible-first описаны в [плане транспорта](../transport-evolution.md).

## Границы среза

Владелец подтвердил, что исправление мигания после отпускания Pencil работает на iPad. Это подтверждение базового рисования, не замена полной device matrix, GPU capture или измерений.

В этом срезе добавлены подготовительные слои M2. Статус ниже относится именно к моменту M2.1; актуальный transport вынесен в следующий отчёт. **Canvas пока не использует их:** рисунки текущего интерфейса остаются локальными и живут в RAM. Нет активного WebSocket, синхронизации с сайтом, reconnect или автоматического replay. Не считать M2 завершённым и не убирать предупреждение локального режима из палитры.

Почему не включён общий мир сразу: сервер отдаёт round/square/chisel/spray, а renderer приложения пока только round. Wire-слой уже понимает все четыре формы, но подменять их круглыми на экране нельзя. До внешней раздачи сетевого клиента нужны остальные renderer-формы и полноценная scene synchronization.

## Реализовано

### `Networking/DrawingEnvironment.swift`

- Нормализованные endpoint и Origin, без userinfo, query и fragment.
- Production допускает только WSS + HTTPS Origin; WS разрешён явно для development.
- Identity scope включает namespace, полный endpoint и Origin. Секреты/очереди не переносятся автоматически между серверами.
- `webSocketRequest()` выставляет Origin, выключает cookie handling и задаёт timeout. Это проверка конструирования URLRequest, **не реальный Upgrade**.

### `Networking/WireProtocol.swift`

- Typed JSON v1: hello/spawn, subscribe, snapshot begin/chunk/end, create/delete, ack/error и live events.
- Канонический immutable `StrokePayload`: только id/points/brush/width/color/opacity. `seq` и `own` невозможно случайно отправить в create.
- Четыре wire brush values, нормализация UUID/цвета, finite world coordinates, точные пары `[x,y]`, ranges, points/extent/viewport limits.
- Safe JS sequence range; create ack требует own=true. Сопоставление request_id с конкретным attempt — работа будущего WorldSession.
- 128 KiB client envelope, 4 MiB server decode cap, не более 1000 strokes/chunk, 2000 points/stroke; размеры коллекций проверяются до их декодирования.
- Неизвестная форма/тип сообщения отклоняются, не становятся round. Необязательные будущие поля сервера игнорируются.
- Не хранится недоверенный `error.message`, наружу не возвращаются raw decoder diagnostics с исходными данными.

Контракт взят из backend `4103b38`, `docs/protocol.md`, SHA256 `7b6ad59cff2b6e58ef5221b3b7e40b6d0db0a6778e4e74e8d24ab264dd02e83b`. Тестовые wire samples синтетические по этому документу; настоящая backend integration ещё не выполнена.

### `Persistence/IdentityStore.swift`

- 32 bytes через `SecRandomCopyBytes`, canonical base64url без padding.
- Generic-password Keychain record: schema version, identity UUID, environment и secret.
- `WhenUnlockedThisDeviceOnly`, без synchronizable/iCloud, раздельные accounts для окружений.
- Только достоверный itemNotFound разрешает генерацию. Locked/unavailable/corrupt Keychain не заменяется новым owner.
- При одновременном создании identity разными stores побеждает один Keychain item; второй store читает тот же owner вместо перезаписи.
- `SessionSecret` намеренно не Codable; description/debugDescription редактированы. Journal принимает только несекретный identity UUID.
- Восстановление ownership после удаления приложения/переноса устройства не обещается.

### `Persistence/OperationJournal.swift`

- Actor-сериализованные транзакции: сначала валидация и atomic write, затем смена RAM state. Ошибка записи не меняет даже in-memory mayHaveBeenSent.
- Snapshot schema привязана к environment + identity. Mismatch, corruption и неизвестная version блокируют работу, а не создают пустую очередь поверх старой.
- Неизменяемые create payloads, delete, mayHaveBeenSent, cancellation, local ordinal и bounded undo history.
- Перед send вызывается `markMayHaveBeenSent`; timeout/разрыв не разрешают удалять операцию.
- Undo unsent create удаляет его локально; undo unknown create сохраняет cancelled state, после create ack атомарно ставит компенсирующий delete.
- Ack проверяет payload/ownership или stroke ID. Дубли ack/delete не создают дубликатов.
- Undo выбирает последнее действие по local ordinal, не по порядку прихода ack; более новый подтверждённый штрих имеет приоритет над старым pending.
- Пределы: 64 unresolved create, 256 delete с резервом под cancelled-create compensation, 500 undo entries, 16 MiB на файл. Переполнение не вытесняет старые операции.
- `JournalFileStorage`: complete file protection, directory excluded from backup, temp+atomic replace. Это не гарантия от физического отказа накопителя.
- Default Application Support path зависит от SHA256 environment scope, **не от identity UUID**: потеря identity должна обнаружить mismatch существующего файла, а не незаметно открыть новый пустой. SHA256 здесь только стабильное имя каталога, не шифрование.

На один файл должен быть ровно один активный OperationJournal. Actor обеспечивает сериализацию внутри своего instance; межпроцессный writer/несколько одновременно активных journal instances не поддерживаются. Будущий WorldSession владеет единственным instance.

## Контракт подключения к WorldSession

Планируемый порядок, ещё не связанный с Canvas:

1. Загрузить Keychain identity для выбранного environment; при ошибке не создавать временного owner.
2. Открыть scoped journal с этой identity; mismatch/corrupt не лечить автоматическим удалением файла.
3. Finalize input без predictions → `StrokePayload` → `enqueueCreate`; до успеха записи не отправлять и не объявлять переживающим restart.
4. Mutation scheduler выбирает operation, сохраняет `markMayHaveBeenSent`, создаёт новый request_id и отправляет `operation.message(requestID:)`.
5. WorldSession коррелирует ack/error/generation с конкретным attempt. Только validated definitive ack/rejection меняет journal; timeout не вызывает `reject`.
6. SceneStore отдельно управляет authoritative region, pending rendering, tombstones и optimistic hide; наличие записи в journal не означает server commit.

## Проверки

Xcode 27.1, SDK 27.1, прежний Metal Toolchain; iPad Pro M4 Simulator:

| Прогон | Результат |
| --- | --- |
| Debug, iPadOS 18.6, ad-hoc signed | 57 PASS, 8 suites |
| Debug, runtime iOS 27.0, ad-hoc signed | 57 PASS |
| Release, runtime iOS 27.0, ad-hoc signed, ENABLE_TESTABILITY=YES | 57 PASS |
| Release generic iOS device, без подписи | BUILD SUCCEEDED; не device runtime test |
| Swift strict concurrency / warnings as errors | PASS |

Новые 30 тестов: 11 wire/environment, 5 identity, 14 journal. Вместе с предыдущими 27 проверками renderer/input/launch — 57.

Проверены реальный Simulator Keychain, восстановление identity, accessibility attribute и конкурентное создание owner. Locked/corrupt Keychain отдельно моделируются через порт. Journal тестируется реальными temp-файлами; сбой записи — через port, не симуляцией физического full-disk/power loss. Проверены replay payload equality, неизвестный commit, compensating delete, out-of-order ack, wrong owner/endpoint, corruption/version, limits/backup flag, duplicate UUID и deduplication.

### Подпись Simulator для тестов

Старый запуск с `CODE_SIGNING_ALLOWED=NO` больше не годится для **всего** test suite: настоящий Keychain возвращает `errSecMissingEntitlement (-34018)` без application identity. Это не ошибка, которую следует скрывать mock-реализацией в integration test.

Использовать стандартную подпись Xcode для Simulator или ad-hoc:

```bash
IPAD_SIMULATOR_ID='<UUID>'
xcodebuild -project 'Endless Drawing.xcodeproj' \
  -scheme 'Endless Drawing' -configuration Debug \
  -destination "platform=iOS Simulator,id=$IPAD_SIMULATOR_ID" \
  -derivedDataPath /tmp/endless-drawing-signed-tests \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- \
  test
```

Для Release заменить configuration и добавить `ENABLE_TESTABILITY=YES`. Обычные release-настройки проекта ради тестирования не изменялись. Сертификат устройства/публикация билда для ad-hoc Simulator теста не нужны.

## Осталось в M2

- Serial URLSessionWebSocketTask transport, настоящий Origin Upgrade и hello на dev backend.
- SceneStore reducer: staging swap, live, request/subscription generations, ack overlays, dedup/tombstones.
- Mutation scheduling/rate limits, deadlines, backoff, replay и lifecycle/unlock handling.
- Подключение identity/journal к Canvas; сохранение pending и отсутствие мигания на новых переходах.
- Поддержка четырёх форм renderer перед открытием произвольной серверной области.
- Настоящий iPad ↔ backend ↔ browser smoke и physical storage/lock проверка.

Локальный `/healthz` на `127.0.0.1:3000` в начале среза был недоступен; backend в этом срезе не запускался и его файлы не изменялись. По README backend staging имеет private gate; фактическую среду и разрешённый Origin нужно согласовать/проверить перед интеграцией. Production strokes при тестировании не создавались.
