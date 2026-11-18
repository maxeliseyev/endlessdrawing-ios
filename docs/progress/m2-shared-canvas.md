# M2.3 — подключение общего холста

## Статус

Обычный запуск приложения в Debug и Release теперь подключается к `wss://endlessdrawing.com/ws` с Origin `https://endlessdrawing.com`. Это уже не RAM-only прототип. Сначала выбирается MessagePack v2 либо explicit JSON v1, затем hello, snapshot и live stream. V3/manifest и visible-first не предлагаются.

Общий путь Canvas → journal → transport → ack включён. Keychain account, owner secret и journal schema/path `v1` не менялись. Новые штрихи считаются pending до durable ack resolution; offline не выдаётся за «сохранено на сервере». Физическая приёмка **подключённой** сборки на iPad ещё нужна.

Тестовый host и Preview не открывают production автоматически. Local mode существует только при явной инъекции `CanvasModel()` для тестов/preview, не как незаметный fallback приложения при сетевой ошибке.

## Что реализовано

### WorldSession и scene

- `World/WorldSession.swift`: hello/snapshot/live FSM, один последовательный receive consumer, correlation единственного активного mutation attempt по request ID. Transport boundary ограничен actor-протоколом.
- Connect watchdog 8 s в transport; hello 8 s, snapshot целиком 35 s, mutation ack 12 s, foreground ping 20 s. Chunk не продлевает общий snapshot deadline.
- Reconnect/backoff с jitter 0.5–10 s, новый hello и новый subscription ID. Нет event cursor по seq. Старые epochs/scopes не изменяют новый мир.
- После трёх подряд snapshot timeouts одинаковая область приостанавливается до смены области/Retry, а не создаёт бесконечный resync storm. Protocol/version errors также ждут Retry; не обходятся legacy downgrade.
- `World/SceneStore.swift`: progressive staging, дедупликация UUID, immutable payload/seq/ownership checks, сортировка по server seq, ack overlays и tombstones. Отсутствующие IDs удаляются из authoritative membership только на snapshot.end. Delete/hidden побеждают late chunk/ack сразу.
- Reconnect и отмена подписки могут сохранять bounded stale display; он не объявляется завершённым snapshot.
- Общий union-budget confirmed/staging/ack: 20 000 strokes / 1 000 000 points; tombstones ≤20 000. Переполнение даёт явное degraded состояние, без молчаливого вытеснения защиты от resurrection.
- `CanvasRegion`: видимая область, render margin 1.3× и prefetch до 3×, максимум 30 000 по оси с world clamp. На 8% iPad viewport помещается в server limit; prefetch ограничивается независимо.
- `RequestPacer`: conservative rolling window 1.1 s, ≤5 create, ≤20 delete, ≤5 subscribe, интервал subscribe ≥300 ms; control traffic входит в общий бюджет 80. В первой реализации один mutation in-flight: это простая безопасная очередь, не обещание максимальной WAN-throughput.

### Persist-before-send, undo и lifecycle

- `CanvasModel` открывает environment-scoped Keychain identity и OperationJournal до приёма Pencil-штрихов. Ошибка identity/journal не заменяет владельца и не очищает очередь.
- Реальные finalized points/style/UUID сохраняются до send. Перед send отдельно durable `mayHaveBeenSent`; retries меняют только request ID, не payload.
- Pending/confirmed и event/ack используют тот же ID/GPU buffer. Исправление Pencil-lift handoff сохранено; predictions не попадают в journal/сеть.
- Undo — только собственная история из journal, не произвольный stroke из snapshot. Unsent create отменяется без сети; unknown create скрывается, подтверждается идемпотентным retry и компенсируется delete. ACK order не меняет порядок undo.
- `rate_limited`/`internal_error` оставляют операцию и дают delayed retry. Definitive rejections показывают безопасное локализованное сообщение; сырые серверные message/decoder diagnostics не отображаются.
- При отказе локальной записи action и видимый draft остаются в RAM, отправка не начинается, показано предупреждение и доступен Retry. Это **не** restart-durable drawing, пока запись не завершилась. Очередь UI сериализует create/undo в пользовательском порядке.
- Journal snapshots имеют process-local revision для защиты публикаций от actor reentrancy; persisted schema не менялась.
- Background/disappear отменяет жест, прекращает сеть/heartbeat и geometry loading; foreground поднимает тот же owner/journal и fresh snapshot. Незавершённый touch не отправляется.
- `CameraStore`: маленькая environment-scoped preference в защищённом Application Support, исключённая из backup. Restore 8–400%, optional server spawn только если камера не восстановлена и пользователь ещё не взаимодействовал; reconnect не телепортирует.

### Все четыре формы и Metal

`Rendering/BrushGeometry.swift` переносит текущие square caps/bevel joins, chisel hull sweep и spray из frontend. Round остаётся прежним. Геометрия считается в Double относительно stroke origin; Float появляется только в GPU buffers.

- Spray radius `max(0.35,min(0.5,width/20))`, максимальный диаметр **1 world unit**, в том числе для старых strokes. Нет legacy 2.5 и brush wire version.
- Seed из lowercase UUID, wrapping FNV-1a/xorshift32; шаг/число частиц/98 304 maximum совпадают с web.
- Round preview использует predictions с measured-prefix handoff. Effect brushes пока отображают только measured samples, поскольку особенно spray может менять spacing при росте длины; не показывают непредсказуемую смесь разных RNG paths.
- 12 pinned numerical web fixtures в `Fixtures/brush-geometry.json`, SHA256 исходников и commit генерации. Обновление только явным `tools/generate-brush-fixtures.cjs`, не во время тестов.
- Metal рендерит настоящие формы в прежнюю union coverage mask, применяет opacity один раз на stroke. Добавлены GPU tests square/chisel/spray и общая Canvas handoff проверка.
- Geometry worker сериализован вне MainActor, загрузка сцены latest-wanted, без задачи на каждый удалённый stroke. Только видимая область с margin готовится в GPU.
- Document geometry GPU cache ≤64 MiB (preview, in-flight/temporary buffers и render targets отдельно), максимум 2000 одновременно drawable records; превышение показывает «приблизьте холст», не подменяет формы и не выбрасывает journal. Это отдельный render budget, не предел server scene membership.
- Offscreen geometry удаляется, draw/composite ограничены stroke scissor + AA padding. Размер render targets также ограничен. Это direct renderer, **не** реализованные тайлы/LOD и не обещание 120 FPS на плотном мире.
- В контекстной палитре появились выбор четырёх кистей, состояние подключения/pending и Retry; постоянного toolbar по-прежнему нет. EN/RU обновлены. Минимум zoom **8%**, максимум 400%.

## Проверки 2026-11-18

Native рабочее дерево поверх `f769baf`, Xcode 27.1, deployment 18.6.

| Проверка | Результат |
| --- | --- |
| Debug, iPad Simulator / iPadOS 18.6 | PASS |
| Debug, iPad M4 Simulator / runtime 27.0 | PASS |
| Release, Simulator 27.0, testability + ad-hoc signing | PASS |
| Release generic iOS device, без подписи | BUILD SUCCEEDED |
| Обычный набор | 107 discovered: 104 выполнены, 3 opt-in сетевых tests пропущены штатно |
| Published WSS, настоящий URLSession, read-only | PASS: selected v2, hello.ack, begin/chunks/end; 9 strokes / 1138 points в данном случайном регионе |
| Native WorldSession ↔ настоящий backend/Postgres | PASS: binary author + legacy JSON observer, четыре brush, own flags, чужой delete запрещён, повтор create с прежним UUID/seq, server undo |
| Сервер `WS_MSGPACK_ENABLED=false` | PASS: native negotiated connection выбирает explicit JSON v1 без второго legacy handshake |

Published read-only test прошёл на Simulator 27.0 за 6.657 s (включая сеть); это не FPS/CPU benchmark. В public world не отправлялись тестовые create/delete. Raw production payload/coordinates/secret не сохранялись в fixtures и не логировались.

Для mutation integration backend собран из committed archive `3bdb9887e7e2c8bf93e3542610f6c1a739a7a19b`, запущен на loopback `33187`, с **отдельной временной БД** в уже работающем dev PostgreSQL 17. Четыре create + retry оставили ровно 4 rows; после undo — 0 live. Затем только наш процесс остановлен и наша БД удалена. Основная dev DB, соседние исходники, VPS и deployment не изменялись. Откат проверен отдельным рестартом только этого процесса.

Unit/in-process проверки включают lost ack → timeout → новый connection/request ID с прежним payload/одной undo записью, delayed ack + компенсацию, rate retry, offline unsent undo, hello timeout, pause после repeated snapshot timeout, scene/tombstone budgets и stale scopes. UI/Metal integration проверяет сохранение реальной линии через persist/event/ack и её удаление после undo; отказ диска оставляет видимый draft, Retry отправляет его только после успешной записи.

## Воспроизведение opt-in gates

Обычный `⌘U` не обращается к публичному миру и не меняет БД.

- `PublishedCanvasTests`: явно задать **test-host** environment `ENDLESS_NATIVE_READ_SMOKE=1`; только чтение опубликованного endpoint, без Keychain/journal пользователя.
- `LocalBackendTests`: `ENDLESS_LOCAL_BACKEND_WS=ws://127.0.0.1:<port>/ws`; тест жёстко отвергает не-loopback URL. Нужен отдельный пустой disposable database, не обычная dev DB.
- Для второго local gate перезапустить тот же изолированный backend с `WS_MSGPACK_ENABLED=false` и добавить test env `ENDLESS_EXPECT_JSON_ROLLBACK=1`; основной mutation test тогда штатно пропускается.
- Test environment можно задать в Xcode Test Action либо копии generated `.xctestrun` рядом с оригиналом. В основной scheme эти флаги не включены. CLI prefix без передачи переменной внутрь test host недостаточен.

Тесты запускаются на подписанном Simulator host: `CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-`. Release tests требуют `ENABLE_TESTABILITY=YES`. Warnings-as-errors заданы только собственным targets, не глобальным override SPM.

## Что ещё не принято

- Физический iPad ↔ браузер: чтение, Pencil drawing, reload с тем же owner, undo, Wi-Fi loss/background, четыре визуальные формы.
- Physical Pencil Pro double-tap/squeeze/hover и eraser hit-test; пока доступны обычное рисование и серверный undo.
- Performance/memory/thermal/GPU capture на плотном общем мире. Direct renderer использует явные бюджеты вместо необоснованных FPS обещаний.
- V3 manifest/cache и server-side visible-first: отдельный следующий срез. Текущий v2 делает full snapshot при переподписке.
- Настройки brush пока не сохраняются между процессами; camera/ownership/outbox/undo сохраняются. Удаление приложения/перенос на другой iPad не является гарантированным восстановлением ownership.
