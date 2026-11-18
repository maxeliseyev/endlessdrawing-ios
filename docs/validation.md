# Проверки и приёмка iPad-клиента

Статус: план. Ни один пункт ниже не означает, что тест уже написан или пройден. Реальные результаты фиксируются отдельным отчётом с revision, устройством, версией iPadOS, конфигурацией сервера и датой запуска.

Связанные документы: [план](implementation-plan.md), [архитектура](architecture.md).

## 1. Уровни проверки

1. Чистые unit-тесты: камера, геометрия, state machine, reducer, scheduler, журнал. Без UI и настоящей сети.
2. Contract fixtures: декодирование wire v1 и численное сравнение геометрии с веб-реализацией.
3. Metal render tests: offscreen textures/readback и допустимые image differences; на CI только при доступном Metal device.
4. Transport integration: настоящий backend + PostgreSQL, контролируемые потери соединения/ответов.
5. UI tests: палитра, локализация, accessibility, lifecycle; не имитируют полную физику Pencil Pro.
6. Физический iPad: Pencil gestures, ладонь, hover, задержка, frame pacing, память/тепло и системные жесты.

Simulator build не подтверждает качество Metal/Pencil на устройстве. Mock server не подтверждает интеграцию с backend. Визуальное ощущение плавности не заменяет чисел кадра.

## 2. Детерминированные fixtures

### Формат и происхождение

В test-only `Fixtures/` хранить:

- `manifest.json`: версия fixture schema, frontend/backend commit, генератор и численные допуски;
- wire frames: hello, snapshot, strokes, acks и errors, без настоящих session secrets;
- geometry inputs и ожидаемые polygons/circle particles в локальных координатах;
- небольшие reference images в известном цветовом профиле;
- сценарии последовательностей сообщений/жестов и ожидаемое состояние reducer.

Синтетические UUID и координаты, фиксированные seeds. Чистая численная геометрия генерируется из существующих веб-функций, а не переписывается руками «по похожей формуле». Файлы не требуют изменения frontend-репозитория: одноразовый генератор/тестовая утилита может читать его исходники, но воспроизведение тестов iPad использует закоммиченные fixtures.

### Набор геометрии

| ID | Сценарий |
| --- | --- |
| G01 | Одиночная точка каждой формы, width 1/6/64 |
| G02 | Горизонталь, вертикаль, диагональ, короткий сегмент, точные дубли |
| G03 | Острый угол, разворот на 180°, петля и self-intersection |
| G04 | Opacity 1 / 0.5 / близко к 0, перекрытие внутри одного и разных strokes |
| G05 | Chisel footprint -45° и sweep через углы |
| G06 | Spray seed из lowercase/uppercase UUID, zero-hash fallback в отдельном RNG unit-тесте |
| G07 | Spray неподвижная точка, длинный путь, максимум stamps/particles |
| G08 | Collinear resampling, разные sampling frequencies с одинаковой траекторией |
| G09 | World origins 0, ±1e6, ±1e9; local offsets и translation invariance |
| G10 | Штрих рядом с world edge и границей viewport/tile, расширенный bbox не обрезается |

Центры полупрозрачных областей сравнивать строго по ожидаемому source-over с небольшим допуском квантования; AA-пиксели — с явно заданной маской/порогом. Не ослаблять весь image diff ради нескольких краёв. Точность trig/Float-conversion отдельно от byte-identical integer RNG.

## 3. Unit и reducer matrix

| ID | Проверки |
| --- | --- |
| C01 | worldToScreen/screenToWorld roundtrip, pan при разных zoom, clamp мира |
| C02 | Zoom anchor invariant, pinch midpoint, 16–400%, server span cap и viewport resize |
| I01 | Real/coalesced дедупликация, predictions заменяются и никогда не сохраняются |
| I02 | Pencil+ладонь, finger pan→Pencil, два пальца→один, третий палец, полное отпускание |
| I03 | Cancel/blur/resign active/rotation не создают payload и undo |
| I04 | Long press thresholds, palette-dismiss touch не начинает stroke |
| I05 | Squeeze began/changed/ended/cancelled, ended-only; preferred action ignore/shortcut/unknown |
| I06 | Смена tool/palette во время draft отменяет его, old predicted tail не возвращается |
| B01 | Finite/ranges/styles/UUID/seq/own; unknown brush не превращается в round |
| B02 | 2000 real points, decimation сохраняет endpoints, encoded envelope ≤128 KiB |
| B03 | Детерминированный spray: wrapping math, последовательность RNG, bounds и hit-test |
| S01 | begin→chunks→end атомарно заменяет область, empty snapshot очищает старое |
| S02 | Late frames старого subscription/generation игнорируются |
| S03 | Own event до ack и ack до event: на экране один ID, одна undo entry |
| S04 | Delete/tombstone до позднего create ack/snapshot не воскрешает stroke |
| S05 | Own ack вне новой области закрывает operation, но не раздувает scoped scene |
| S06 | Отмена snapshot/resync оставляет stale display до успешной замены, не смешивает authority |
| S07 | Превышение scene/staging/tombstone budget не даёт бесконечного resync или тихой полной готовности |
| O01 | Ack timeout/disconnect повторяет тот же UUID и численный payload |
| O02 | Undo unsent create не шлёт delete; sent/unknown create завершается и компенсируется delete |
| O03 | Ack пришли в обратном порядке: undo следует local ordinal |
| O04 | Duplicate delete ack/event, not_found, forbidden, already_deleted и rollback |
| O05 | Rate windows 5/20/5, очереди bounded; замена latest bounds не теряет мутации |
| O06 | Monotonic clock, backoff/jitter с инъекцией RNG, cancellation при смене generation |
| P01 | Crash/restart до send, после записи mayHaveBeenSent, после commit до ack, после ack до journal commit |
| P02 | Atomic journal replace, unsupported version, повреждение, полный диск/queue limit |
| P03 | Keychain locked/error ≠ itemNotFound, secret не регенерируется при transient failure |
| P04 | Environment/identity mismatch блокирует replay; один payload не отправляется другому серверу |
| P05 | Удаление из undo и закрытие операции согласованы при перезапуске |

Fake clocks, identity/storage ports и transport должны инъецироваться в тесты; не использовать sleep для проверки логики deadline/rate limit.

## 4. Metal render и resource tests

- Все G01–G10 на direct pipeline; после появления tiles — те же inputs и сравнение direct/tiled.
- Проверить, что overlap сегментов/частиц внутри stroke при opacity 0.5 не темнее одиночного участка.
- Последовательность stroke IDs по seq, pending поверх canonical, переход event/ack не удваивает alpha.
- Tile gutter и швы при fractional pan/zoom, разных drawable ratios и после settle LOD.
- Delete/optimistic hide не показывает старый dirty tile ни как основной, ни как LOD fallback.
- Insert старого seq вызывает rebuild, append нового seq не перерисовывает незатронутые тайлы.
- Большой stroke с несколькими local origins/batches всё ещё имеет единый coverage composite.
- GPU resource eviction не освобождает in-flight buffers/textures; нехватка drawable/frame slot не блокирует input thread.
- Memory warning и allocation failure освобождают кеши, сохраняют outbox/active state и восстанавливают renderer.
- Metal API Validation и GPU validation: нет read/write feedback, неверного pipeline format/sample count или out-of-bounds buffer access.
- Покой без изменений не кодирует непрерывные пустые кадры; входящее событие будит renderer.

## 5. Реальная интеграция с backend и сайтом

Использовать отдельный dev/test мир, не рисовать тестовыми сценариями в production. Адреса и Origin брать из конфигурации стенда. Для секретов — ephemeral test identity, не печатать hello в test logs.

### Обязательный smoke

1. iPad и браузер с разными секретами подписаны на одну область.
2. iPad создаёт round: получает own=true, браузер видит own=false; обратное направление также работает.
3. Повторить для square/chisel/spray и полупрозрачных пересечений, сверить screenshots/fixture points.
4. Каждый клиент удаляет своё; чужое delete отклоняется сервером, локальный UI чужое не скрывает.
5. Undo удаляет stroke у обоих; повторное удаление безопасно.
6. Оборвать соединение после commit, до ack: после reconnect не возникает второго stroke/undo.
7. Завершить процесс iPad с unresolved create/delete: запуск восстанавливает immutable operations с прежней identity.
8. Создавать/удалять во время многочастного snapshot; после end состояние согласовано.
9. Быстро менять viewport/subscription: late chunks не загрязняют новую область.
10. Вызвать `resync_required`/overflow на test environment; следующий snapshot восстанавливает сцену, без вечного retry storm.
11. Background/foreground и lock/unlock дают новый hello/snapshot без смены owner и телепортации камеры.
12. Долгий idle не разрывается из-за неправильного ping/pong; transient потеря сети восстанавливается.

### Transport/security cases

- Разрешённый Origin проходит; отсутствующий/неразрешённый даёт 403. Не исправлять тест отключением allowlist.
- Невалидный session secret, hello timeout и неподдержанная protocol_version дают контролируемый отказ.
- Неправильный JSON, oversized text, неожиданный binary frame и неизвестная структура не вызывают crash/unbounded allocation.
- TLS validation штатная; неправильный сертификат и cross-host redirect не обходятся trust-all кодом.
- Wi-Fi→offline→Wi-Fi, переключение сети, slow receive/send, server restart/503 и длительный snapshot.
- Debug LAN на физическом iPad не использует 127.0.0.1 Mac по ошибке; проверить Local Network permission/ATS отдельно от production.
- Если staging закрыт IP/private gate, доступ согласован с оператором. URLSession не обходит этот gate и не заменяет серверные допуски.

## 6. Устройства и доступность

Обязательное исходное устройство — iPad Pro M4 + Apple Pencil Pro владельца. Дополнительные устройства используются при фактической доступности, не указывать их как проверенные заранее.

| Конфигурация | Что проверить |
| --- | --- |
| iPad Pro M4 + Pencil Pro | Double tap, squeeze, hover, ладонь, 120 Hz, roll не меняет v1-рисунок |
| iPad с 60 Hz | Frame budget, finger gestures, отсутствие предположения 120 Hz |
| Обычный Pencil / отсутствие hover | Основное рисование, альтернативный доступ к палитре, no-op неподдерживаемых жестов |
| Без Pencil | Finger pan/pinch, long press, VoiceOver/tools; отсутствие скрытой зависимости от первого Pencil event |
| Hardware keyboard / trackpad | Secondary click, context menu shortcut, ⌘Z, фокус полей |

На каждом физическом устройстве фиксировать модель, iPadOS, Pencil model, power/thermal mode, ориентацию и размер окна.

Чек-лист:

- ладонь во время Pencil не рисует и не перемещает камеру;
- быстрые линии и замена predictions не оставляют раздвоенный хвост;
- squeeze с отсутствующим hover pose открывает доступную палитру, не за экраном;
- Settings для tap/squeeze/ignore/hover действительно соблюдаются;
- поворот, Stage Manager resize, split view, home/edge gestures и lock отменяют только незавершённое;
- палитра сохраняет доступность над клавиатурой/home indicator, цели ≥44 pt;
- VoiceOver может открыть/закрыть инструменты и выполнить undo, не попадая в ловушку canvas gesture recognizers;
- Dynamic Type и длинные EN/RU подписи не обрезают важные controls;
- тёмный системный режим не превращает белый общий мир в другой рисунок.

## 7. Performance-план

### Воспроизводимые сцены

- Пустой мир и один длинный активный round.
- 1000, 5000, 20000 простых strokes в области, с отдельно записанным общим point count.
- Смесь 4 форм, opacity 0.5 и много self-overlap.
- Один максимальный spray, затем несколько плотных spray в кадре; учитывать particles, не только strokes.
- Камера на ±1e9, zoom 0.16 / 1 / 4, быстрый pan/pinch и остановка.
- Сцена сверх лимита памяти для проверки degraded policy, а не требования отрисовать бесконечность.

### Начальные цели, не обещания

| Метрика | Цель для проверки |
| --- | --- |
| Ритм активного кадра | Около 8.33 ms на 120 Hz или 16.67 ms на 60 Hz при согласованной benchmark-сцене |
| Input handling p95 | <2 ms без синхронного I/O и тяжёлой тесселяции |
| CPU frame encoding p95 | <4 ms на целевом M4 в базовой сцене |
| GPU frame duration p95 | <6 ms на целевом M4 в базовой сцене; измеряется отдельно |
| Повторный pan по прогретой области | Нет geometry rebuild всего мира; только tile placement/необходимые новые тайлы |
| Покой | Нет постоянного display loop и ненужной загрузки CPU/GPU |
| Память | Кеши соблюдают byte caps, transient и in-flight allocations видны отдельно; нет роста при повторных pan/reconnect |
| Pending/reconnect | Отрисовка не ждёт roundtrip сети, но UI не объявляет commit до подтверждения |

CPU/GPU targets не складываются механически и сами по себе не доказывают 120 Hz. Проверять frame pacing/missed frames и headroom на реальном pipeline. Сквозную Pencil-to-photon latency нельзя честно вывести только из CPU signposts; для точного значения нужен отдельный метод измерения, например high-speed camera.

Инструменты: Instruments, Metal System Trace, GPU frame capture, Allocations/Memory Graph, signposts. Замеры Release/Profile без Metal validation, а correctness captures — отдельно с validation. Повторить после 10–15 минут работы для thermal effects. Performance regression сравнивать на одном устройстве/OS/сцене/настройках.

## 8. Формат отчёта и release gate

Для каждого прогона записать:

```text
App revision / build:
Frontend/backend revision:
Endpoint environment / Origin (без секретов):
Device / iPadOS / Pencil:
Scene fixture / point+particle counts / zoom:
Configuration / power / thermal state:
Automated results:
Manual checks:
CPU / GPU / frame pacing / peak memory:
Known failures / screenshots / capture references:
Decision: pass / blocked / follow-up
```

Перед TestFlight обязательны: simulator build, Release device build/archive, unit/contract tests, Metal correctness на физическом iPad, реальный WS smoke с сайтом, восстановление crash/outbox, ownership security cases и отсутствие секретов в логах/backup.

Открытые issues классифицировать: потеря/дублирование/неверное ownership и resurrection — блокирующие; визуальная несовместимость кистей и некорректная opacity — блокирующие; performance ниже принятой цели требует измерений и согласованного ограничения, а не переименования статуса «готово».
