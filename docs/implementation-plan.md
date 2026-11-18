# План разработки iPad-клиента

## 1. Статус и границы документа

Основа согласована владельцем в текущем обсуждении: отдельное нативное iPad-приложение, SwiftUI + UIKit + Metal, общий WS backend и Keychain. Metal выбран для плавности и аппаратного ускорения на устройстве.

Дополнительно принята транспортная эволюция из frontend docs: MessagePack v2, authoritative manifest с geometry fetch только отсутствующего, затем приоритет visible geometry перед prefetch. Эти изменения внедряются совместно с backend и имеют отдельные этапы/версии, а не включаются только на iPad. Статус, native API и rollout gates: [transport-evolution.md](transport-evolution.md).

Остальное ниже — проект реализации этой основы. Числа бюджетов, внутренние типы и поведение в спорных UX-ситуациях являются предлагаемыми решениями, а не результатами измерений или уже работающими возможностями.

На момент составления:

- приложение — стандартный SwiftUI/SwiftData-шаблон (`ContentView.swift`, `EndlessDrawingApp.swift`, `Item.swift`);
- target — iPad, minimum iPadOS 18.6; без Catalyst и Mac Designed for iPad;
- локально установлен Xcode 27.1; availability используемых Pencil API проверена по UIKit headers, но приложение с ними ещё не собрано;
- в рабочем дереве уже есть переименования файлов/проекта владельца; не отменять и не смешивать с архитектурными изменениями;
- код веб-клиента и backend изучается как контракт; изменения в соседних репозиториях в этот план работ не входят автоматически.

**Текущий прогресс:** [M2.3](progress/m2-shared-canvas.md) включает production Canvas, WorldSession/SceneStore, durable journal/send/ack/undo и четыре кисти; zoom 8–400%. 107 tests discovered (104 ordinary + 3 explicit network gates), actual native read-only published WSS и isolated backend/Postgres mutation/JSON rollback проверены. Подключённая сборка ещё требует physical iPad ↔ browser acceptance; GPU/performance, eraser и Pencil Pro gestures не закрыты.

Реализацию вести вертикальными срезами, каждый заканчивается проверяемым поведением. Не начинать сразу с полного тайлового движка и всех инструментов.

## 2. Принятые решения

| ID | Решение | Следствие |
| --- | --- | --- |
| D01 | Отдельный нативный клиент, не WebView | Собственные ввод и рендер; общий сервер и мир |
| D02 | SwiftUI + UIKit | SwiftUI-палитра и композиция; UIKit canvas controller и touch state machine |
| D03 | Metal / MetalKit | `MTKView`, собственная геометрия, coverage и GPU-кеши |
| D04 | Общий WS: MessagePack v2 с переходной поддержкой JSON v1 | Codec negotiation до hello; семантика мутаций и один socket сохраняются, backend выкладывается первым |
| D05 | Секрет владельца в Keychain | Право удаления сохраняется после обычного перезапуска приложения |
| D06 | UI соответствует продукту | Нет onboarding, брендинга поверх холста и постоянной панели |
| D07 | Совместимость с веб-геометрией | Нельзя незаметно заменить chisel/spray на другую кисть |
| D08 | Manifest + missing geometry для смены области | Сверять полный состав и удаления в overlap; точный wire — следующая согласованная версия после v2 |
| D09 | Видимая область раньше prefetch | Приоритет в одном согласованном snapshot, progressive display и композиция всегда по seq |

### Что сознательно не входит в v1 приложения

- Переменная толщина/opacity от нажима, угол chisel от наклона или barrel roll: у WS v1 нет этих полей. Данные пера можно читать для локальной диагностики, но preview не должен обещать несохраняемый эффект.
- Аккаунты, синхронизация секрета через iCloud, импорт ownership из браузера.
- Административная модерация в публичном приложении, экспорт, слои, выделение и частичный ластик.
- Бесконечная offline-очередь, полная локальная копия мира, multiwindow и несколько одновременно активных соединений приложения.
- Гарантия 120 FPS на любом iPad. Это измеряемая цель для подходящего устройства, не свойство самого выбора Metal.
- PencilKit как формат документа или основной renderer: общий мир хранит другую каноническую геометрию.

## 3. Целевой UX первой версии

- Запуск сразу на белом общем холсте. Нет тестовых рисунков вместо серверных данных.
- По умолчанию round, `#202020`, width 6 world units, opacity 1.
- Pencil рисует; пальцы перемещают и масштабируют. Во время штриха Pencil пальцевые жесты не меняют камеру.
- Предлагаемый стартовый режим приложения — Pencil-first: пальцы не рисуют, даже до первого Pencil-события. Это намеренное отличие от сайта. Рисование пальцем можно спроектировать отдельно при необходимости.
- Double-tap и squeeze исполняют выбранное пользователем системное действие. Типовой сценарий — кисть/ластик и открытие палитры; жёстко переопределять Settings нельзя.
- Hover показывает реальный наконечник только если разрешён системными предпочтениями; отсутствие hover не ломает палитру.
- Палитра доступна также через long press пальцем, secondary click и доступное accessibility-действие холста; Pencil Pro не единственный путь к инструментам.
- Ластик удаляет целый собственный штрих. Undo использует ту же серверную операцию delete.
- Зум 16–400%, точка под серединой pinch сохраняет положение; мир ограничен ±1e9.
- Палитра: Кисть / Рука / Ластик, четыре формы, быстрые цвета и произвольный цвет, width, opacity, undo и управление зумом. Интерактивные цели не меньше 44 pt.
- Короткие сообщения только при настоящей проблеме. Pending не называется «сохранено» до серверного подтверждения; доступный по запросу статус очереди находится в палитре.
- Английский и русский по системному списку предпочтительных языков; без отдельного экрана выбора.

Подробности и проектные решения пограничных случаев: [architecture.md](architecture.md).

## 4. Этапы и выходные критерии

### M0 — документация и фиксация контрактов

- [x] Записать принятую основу и границы v1.
- [x] Спроектировать слои, владение состоянием, жизненный цикл и Metal pipeline.
- [x] Описать Pencil-жесты, snapshot/ack races и восстановление операций.
- [x] Составить план автоматических проверок и device acceptance.
- [x] Снять baseline исходного проекта: simulator build без подписи, доступные simulator destinations.
- [ ] Проверить нативный WS Upgrade с явным Origin на dev-стенде, зафиксировать адрес/allowlist.
- [x] Подготовить versioned fixture-набор round из веб-геометрии, с commit и SHA256 источников; остальные формы — на M3.

**Выход:** подготовительный M2.1 совместим с текущим v1. Новые transport profiles и manifest/priority extensions вводятся только согласованными версиями; серверные настройки, fixtures и rollout dependencies явно перечислены.

### M1 — локальный вертикальный срез Metal + Pencil

- [x] Убрать использование шаблонных `Item`/SwiftData из приложения, не менять bundle ID, signing и пользовательские переименования.
- [x] `CanvasViewController` + `MTKView` внутри SwiftUI; код обработки resize/drawable size и app lifecycle; явный single-scene manifest.
- [x] Чистая модель камеры и преобразования pt ↔ world; Double на CPU, локальные Float на GPU.
- [x] Round geometry: точки, сегменты, caps/joins, полупрозрачный self-overlap без повторного затемнения, подтверждено offscreen render tests.
- [x] Код real/coalesced samples, отдельный заменяемый predicted tail, отмена незавершённого жеста; sampler покрыт unit-тестами.
- [x] Код finger pan/pinch, long press и минимальной палитры; отмена при фоне, rotation и системном cancel. UIKit-сценарии требуют device acceptance.
- [x] Код рендера по необходимости в покое и frame loop при активном взаимодействии; тесселяция на serial worker actor.
- [x] Unit/fixture-тесты камеры, ввода и round; offscreen Metal tests, Debug device build без подписи и Release simulator build.
- [x] Владелец подтвердил базовое рисование на iPad и устранение мигания после отпускания Pencil.
- [ ] Полная физическая приёмка UIKit-сценариев, GPU capture и замеры плавности/задержки; не считать их выполненными по подтверждению базового рисования.

**Выход:** на iPad можно плавно рисовать локально и перемещать холст. Нет утверждения, что эти линии общие или сохранены на сервере. Временный локальный режим доступен в Debug и Release для приёмки на устройстве, явно обозначен в палитре и не является продуктовым fallback вместо сети. Публичный выпуск до подключения общего мира не готов.

### M2 — первый общий штрих с сайтом

- [x] Typed DTO, runtime validation, безопасное декодирование недоверенного JSON (слой M2.1).
- [x] Pinned backend corpus обеих версий энкодера читается Swift; Swift output читается bounded frontend codec. Выбран msgpack-swift 2.0.6, bounded preflight и float64 output adapter проверены.
- [x] Codec boundary с profile-aware hello/version, Text/Binary, byte и chunk-point caps; JSON v1 compatibility сохранена.
- [x] Actual Swift client frames прочитаны настоящим backend: отдельный native WorldSession ↔ Postgres smoke, четыре кисти, mixed binary/legacy, ownership/idempotency/undo; не только codec self-round-trip.
- [x] `IdentityStore`: 32 криптографически случайных байта, Keychain и разделение окружений (M2.1), подключён к Canvas в M2.3.
- [x] Standalone `WebSocketTransport`: Origin, selection до hello, bounded serial send/receive, Ping/Pong, cancellation/generation guards и loopback tests.
- [x] `WorldSession`: application hello/snapshot/ack FSM, progressive authoritative scene, reconnect/backoff, deadlines и one-in-flight mutation scheduler.
- [x] Published native read-only v2 Upgrade/hello/snapshot подтверждён; отсутствие selected profile не обходит handshake. Server JSON rollback проверен на isolated backend.
- [x] Слой bounded durable outbox: immutable create/delete, persist-before-send marker, компенсация отменённого unknown create, restart/identity guards.
- [x] Identity/outbox подключены к finalize/send. До local write draft только в RAM, до ack — pending; ошибки записи не отправляют и не уничтожают RAM draft.
- [x] Preview → pending → confirmed; event/ack дедупликация и GPU handoff, включая shared-path regression tests.
- [x] Prefetch/переподписка, generation/scope guards, progressive staging; authoritative absence только на end.
- [x] Reconnect/backoff, ack retry с прежним payload, bounded retry и pause dense/snapshot-timeout areas.
- [x] Bootstrap загружает прежний outbox; lifecycle останавливает/возобновляет тот же world, camera сохраняется. Restart state machine и fail-closed storage проверены unit tests.
- [ ] Physical hard-kill/relaunch/lock и iPad ↔ browser smoke на опубликованном мире: не подменяется Simulator/Postgres проверками.

**Выход:** первый round-штрих работает в общем мире, включая потерю ack и перезапуск; JSON/MessagePack coexistence подтверждена после dual-profile backend rollout. До открытия произвольной существующей области renderer обязан понимать все серверные формы: оставшиеся формы подключить здесь либо завершить M3 до внешней раздачи; неизвестную форму не рисовать как round.

Транспортные manifest/missing и visible-first — отдельные T2/T3 gates из [transport-evolution.md](transport-evolution.md), не считаются выполненными от одного MessagePack или progressive display. Их точные сообщения/новый profile сначала фиксируются совместно, затем реализуются и проверяются на delete/hide/cancellation/eviction гонках.

### M3 — полноценные инструменты и Pencil Pro

- [x] Square, chisel и spray по существующему визуальному контракту, общие numerical fixtures с сайтом и Metal tests; физическая визуальная приёмка впереди. Spray: максимальный диаметр 1 world unit вместо 2.5, radius `max(0.35,min(0.5,width/20))`; все старые штрихи перерисовываются новым алгоритмом, без legacy-ветки и смены wire.
- [ ] Analytical hit-test каждой формы, допуск 4 экранных pt; пространственный отбор кандидатов.
- [ ] Удаление только `own`, optimistic hide/rollback; чужие штрихи не выбираются ластиком.
- [x] Undo pending/confirmed через journal и server delete, компенсация unknown create; controlled faults и real-backend проверены.
- [ ] `UIPencilInteraction`: preferred tap/squeeze actions, phase и fallback без hover pose.
- [ ] Hover preview, отмена predicted tail перед палитрой, корректное переключение инструментов.
- [ ] Полная контекстная палитра, EN/RU, VoiceOver, Dynamic Type, hardware keyboard.
- [ ] Сохранение настроек/камеры и undo; палитра учитывает safe area и клавиатуру.

**Выход:** все четыре кисти выглядят совместимо с сайтом; Pencil Pro и альтернативный доступ к инструментам проверены на устройстве.

### M4 — ограниченная стоимость кадра и памяти

- [ ] Профилировать M2/M3 до оптимизации; сохранить capture и воспроизводимые сцены.
- [ ] Пространственный индекс, immutable geometry cache и GPU buffer LRU.
- [ ] World-aligned raster tiles, levels of detail, dirty regions и incremental append.
- [ ] Frame-budgeted rebuild, pinch fallback без смешивания разных масштабов в одной области.
- [ ] Bounded CPU/GPU allocations, batching тяжёлого spray, memory warning и thermal policy.
- [ ] Metal validation, GPU frame capture, Instruments/Metal System Trace и signposts.
- [ ] Сравнить baseline и tile pipeline на одинаковой сцене/устройстве.

**Выход:** pan готовой сцены не пересобирает её геометрию; delete не оставляет ghost; память ограничена в плотном мире; FPS и задержка описаны измерениями.

### M5 — интеграционная приёмка и подготовка TestFlight

- [ ] Настоящий HTTPS/WSS-стенд, TLS, Origin, private gate/IP allowlist, если они включены.
- [ ] Два независимых владельца, все формы, ownership/undo, snapshot races и network faults.
- [ ] Device matrix: Pencil Pro на iPad Pro M4, обычный Pencil при доступности, без hover/squeeze.
- [ ] Реальные 60/120 Hz, фон/lock/rotation/Stage Manager, системные жесты от краёв.
- [ ] Иконка, launch metadata без дополнительного welcome screen, privacy review логов и backup.
- [ ] Release build/archive, signing/TestFlight и чек-лист конкретной версии iPadOS.
- [ ] Записать ограничения и результаты; не отмечать физическую приёмку по simulator/mocks.

**Выход:** воспроизводимый release candidate без неразрешённых ошибок потери/дублирования операций. Публичность backend — отдельное эксплуатационное решение, не следствие выпуска приложения.

## 5. Порядок ближайшей реализации

После M2.3 продолжать небольшими проверяемыми срезами:

1. Physical iPad ↔ browser acceptance: четыре кисти, undo, restart/ownership, background/Wi-Fi loss; не дублировать уже пройденный isolated Postgres gate.
2. Измерить performance/память/thermal на shared мире и проверить явные dense budgets; direct renderer не объявлять тайловым.
3. Native v3/manifest — по действующему backend контракту и fixtures, не добавлять поля в v2 и не включать offer до готовности FSM.
4. Eraser hit-test и Pencil Pro gestures как отдельные срезы, сохраняя geometry/wire parity.
5. Дополнить physical/WAN fault matrix: неизвестный ack при реальном JSON↔binary rollback, hard kill и lock/unlock.
6. Принять для native действующий manifest v3 и реализовать T2 с overlap deletes, cache/pinning и отменой fetch.
7. Отдельно принять visible-first extension, реализовать T3 внутри одного snapshot и сравнить cold/warm/WAN first visible paint.

Не ждать готовности оптимизированных тайлов для проверки сети, и не выпускать сетевой клиент, неправильно рисующий уже существующие формы.

## 6. Открытые решения и риски

| Вопрос | Рабочее предложение | Когда закрыть |
| --- | --- | --- |
| Нажим/наклон/barrel roll в рисунке | Не менять геометрию в v1; отдельный версионированный дизайн протокола | До расширения формата |
| Finger drawing | Pencil-first, пальцы только навигация | Проверить UX на M1 |
| Палитра во время штриха | Отменить незавершённый штрих, не посылать обрезок | Device acceptance M3 |
| Долговечность ownership | Локальный Keychain, без облака/экспорта; не обещать восстановление после удаления приложения | M2/privacy review |
| Offline outbox | Ограниченная восстанавливаемая очередь, не offline-копия мира | M2 |
| Origin и доступ к staging | Явный разрешённый Origin, native protocol negotiation и real Upgrade; не отключать allowlist | M0/M2 |
| MessagePack dependency | Проверить Codable mapping, caps, key validation, precision и межъязыковой corpus до подключения library | T1 |
| Manifest/visible-first wire | Отдельный следующий профиль/контракт; retention/fairness/limit outcomes и cold-cache RTT ещё требуют фиксации | T2/T3 |
| Цвет/AA | Сверка с web fixture; не включать linear-light compositing без сравнения | M1/M3 |
| 120 Hz и расход батареи | Активный high refresh, сон в покое, адаптация к thermal state | M4 |
| Плотная сцена выше лимитов | Явный degraded state и краткое уведомление, без вечного resync | M4 |
| Хранение секретов при backup/reinstall | Device-only key, связанные журналы исключены из backup, fail closed при mismatch | M2 |

## 7. Definition of done для каждого среза

- Код собирается для iPad simulator и, когда затронуты Metal/Pencil, проверен на устройстве.
- Чистая логика покрыта тестами; wire/geometry fixtures не подменены догадками.
- Нет сетевого I/O, JSON/MessagePack decoding, дисковой записи или полной тесселяции мира на UI hot path.
- У всех очередей/кешей есть предел, политика переполнения и тест.
- Отмена задач/смена поколения не позволяет старым результатам менять новую сцену.
- Неподтверждённое не считается серверно сохранённым; секреты и hello не логируются.
- Документация отмечает фактический статус отдельно от плана.

Матрица тестов и начальные performance-цели: [validation.md](validation.md).
