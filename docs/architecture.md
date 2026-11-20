# Архитектура нативного iPad-клиента

Статус: целевая архитектура с частичной реализацией. В [M2.3](progress/m2-shared-canvas.md) включены общий Canvas, WorldSession/SceneStore, journal/send/ack/undo и все четыре Metal-кисти, поверх M2.1/M2.2. Обычный app entry — production v2/v1; тесты/preview изолированы. Тайлы, однопроходная композиция и параллельная геометрия реализованы в [M4](progress/m4-render-cache.md) (на iPad ещё не измерены); eraser и Pencil Pro gestures ещё не реализованы; physical shared-world/performance acceptance остаётся. Исторический локальный срез — [M1](progress/m1-local-canvas.md). Принятая основа и этапы: [implementation-plan.md](implementation-plan.md). Числовые бюджеты ниже — начальные настройки для проверки, не измеренные показатели.

## 1. Источники совместимости

| Область | Источник в соседних репозиториях |
| --- | --- |
| Сообщения, ownership, snapshot, лимиты | `../endless-drawing-backend/docs/protocol.md`, особенно реализованный профиль §10 |
| Фактическая конфигурация транспорта | `../endless-drawing-backend/README.md`, разделы realtime/Origin |
| UX и отсутствие постоянных панелей | `../endless-drawing-frontend/docs/product.md` |
| Кисти и детерминированный spray | `../endless-drawing-frontend/docs/brushes.md`, `src/brush-geometry.ts` |
| Базовая геометрия | `../endless-drawing-frontend/src/webgl/tessellate.ts` |
| Камера и prefetch | `../endless-drawing-frontend/src/camera.ts` |
| Сцена/операции и полезные race cases | `../endless-drawing-frontend/src/scene.ts`, `src/world.ts` |
| Текущий web GPU pipeline | `../endless-drawing-frontend/docs/webgl.md` |
| MessagePack v2 M1 | `../endless-drawing-backend/docs/protocol-v2-msgpack.md`, [реализация native](progress/m2-msgpack-transport.md) |
| Будущие manifest и visible-first | [Нативная адаптация и ссылки на source docs](transport-evolution.md) |

Базовые HEAD при исследовании: iPad `c6f9eee`, frontend `75b59f1`, backend `4103b38`. Во frontend `src/` чист относительно этого HEAD, но прочитанные `docs/product.md` и `docs/webgl.md` имеют локальные изменения; их содержание нельзя приписывать только commit `75b59f1`. В iPad-проекте также есть существующие локальные переименования/настройки.

При переносе фиксировать commit/hash источника рядом с fixtures, а для изменённых файлов — также hash содержимого. При расхождении prose и runtime не выбирать молча удобный вариант: добавить совместный тест и согласовать контракт.

## 2. Компоненты и владение состоянием

```text
SwiftUI App / ContentView / ContextPalette
                 │ commands / small observable view state
                 ▼
       CanvasCoordinator (@MainActor)
        │                │                │
        ▼                ▼                ▼
CanvasViewController   WorldSession     FrameScheduler
UIKit / InputMachine    actor              │
        │                │                  ▼
        │          SceneStore/reducer   MetalRenderer
        │          OperationJournal     │ geometry workers
        │          MutationScheduler    │ GPU buffers / tiles
        │                │              │
        └── active preview + immutable RenderSnapshot ──┘
                         │
                  WebSocketTransport
                         │
                   Shared WS backend (v1/v2)
```

### Границы

- `CanvasCoordinator`: камера, текущие настройки/инструмент, жизненный цикл, доставка команд и небольшое наблюдаемое UI-состояние. Не публикует через SwiftUI каждый touch sample или весь массив штрихов.
- `CanvasViewController`: `MTKView`, UIKit touch events, gesture recognizers только для пальцев/secondary click/hover; маршрутизация accessibility-команд.
- `InputMachine`: детерминированные переходы жестов и сборка активного draft; не знает про socket, Keychain или Metal.
- `WorldSession` actor: единственный владелец состояния общего мира и последовательности сетевых операций. `SceneStore` и reducer — его синхронные чистые помощники, не отдельные actors с независимым порядком событий.
- `WebSocketTransport`: один socket, одна receive loop и один последовательный send path. Проверяет negotiated profile до hello, не изменяет сцену и отдаёт сообщения строго в порядке получения.
- `SessionCodec`: отдельная граница Text JSON v1 / Binary MessagePack v2, structural budgets и profile-aware validation. Выбирается один раз на connection generation; не знает про ownership, journal или Metal.
- `OperationJournal`: последовательная запись локальных транзакций вне main thread; связанный с identity/environment, версионированный bounded outbox и undo.
- `GeometryBuilder`: чистое построение неизменяемой геометрии, доступное тестам без UIKit/Metal.
- `MetalRenderer`: единственный владелец mutable GPU-кешей. Для M1 кодирование команд остаётся на main thread и укладывается в небольшой бюджет; тяжёлая геометрия строится workers. Перенос кодирования на serial render executor — только после профилирования, без смены контрактов.
- `FrameScheduler`: объединяет invalidations, управляет активным frame loop/сном; не запускает независимый loop на каждую пришедшую точку.

### Concurrency-инварианты

- Через границы передаются immutable value snapshots/deltas с `revision` и `Sendable`-данными, а не общий mutable словарь.
- Не создавать `Task` на каждое WS-сообщение: async decoding/доставка не должны переставлять begin/chunk/end и delete/ack.
- Каждая async-работа несёт `connectionGeneration`, `sceneRevision` или geometry revision. Устаревший результат отбрасывается до публикации.
- Actor reentrancy учитывается явно: после `await` journal/transport повторно проверяется generation и состояние операции. Обновление сцены выполняется одной reducer-транзакцией.
- UI применяет только возрастающие scene revisions; промежуточные render snapshots можно объединять, канонические сетевые события и journal writes — нельзя терять.
- В проекте включён `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. При реализации явно проектировать isolation чистых моделей/workers под доступный Swift toolchain, включить strict concurrency checks; не обходить их массовым `@unchecked Sendable`.

## 3. Модель данных и координаты

### Основные сущности

| Тип | Содержимое |
| --- | --- |
| `WorldPoint` / `WorldBounds` | Double x/y, finite, диапазон мира; bounds с min < max |
| `Camera` | Double center x/y, zoom, независимый от drawable pixels |
| `BrushStyle` | round/square/chisel/spray, width, RGB8, opacity |
| `StrokeDraft` | UUID, immutable points и style; только клиентские wire-поля |
| `ServerStroke` | Draft + положительный `seq` и `own` от сервера |
| `InputSample` | Реальная точка, monotonic timestamp, локальные Pencil metadata |
| `ActiveStroke` | UUID + style на момент начала + реальные samples + отдельный predicted tail |
| `PendingOperation` | immutable payload, local ordinal, статус отправки/отмены, identity/environment |
| `RenderSnapshot` | Упорядоченные references/handles, pending, preview, hidden IDs и revision |
| `PreparedGeometry` | Double origin + local Float mesh/circle instances и byte cost |

`seq` хранить в Int64 с проверкой `1...9_007_199_254_740_991`; это порядок создания, не курсор изменений. UUID нормализовать к lowercase для seed и идентификации. В wire points — массивы `[x, y]`, не объекты `{x, y}`. Стиль завершённого штриха неизменяем.

### Единицы

- UIKit и UI работают в points. При zoom=1 одна world unit соответствует одному pt, аналогично CSS px в веб-клиенте.
- `screen = (world - camera.center) * zoom + viewportSize / 2`.
- `world = (screen - viewportSize / 2) / zoom + camera.center`.
- Для GPU использовать реальный `drawableSize / view.bounds.size`, не предполагать, что он всегда равен `UIScreen.scale`; учитывать отдельно x/y при округлении.
- Pinch удерживает world-point под исходной серединой пальцев и переносит его к текущей середине. Zoom clamp 0.08...4 (8–400%, по решению владельца), center clamp ±1e9.
- Видимая область — из камеры и реального размера canvas. Запрос подписки ограничен 30000 world units по каждой оси; при необычно большом viewport адаптировать минимальный zoom так, чтобы видимая область помещалась в лимит.

### Точность GPU

Абсолютные world coordinates нельзя хранить одним Float: возле 1e9 шаг float32 порядка 64 units. На CPU камера и исходные points всегда Double.

Для первого pipeline origin каждого штриха вычитается из camera/tile origin в Double на CPU, затем в GPU передаются локальные Float offsets и небольшой относительный translation. CPU не пересоздаёт mesh при pan. Длинную геометрию при необходимости делить на локальные chunks с отдельными Double origins, но композитить как один логический штрих.

Если batching потребует абсолютных origins в общей GPU-таблице, использовать hi/lo Float-пару, как в `src/webgl/float.ts`. Нельзя просто перейти к абсолютному Float ради уменьшения draw calls. Проверки точности — обязательны на ±1e9 и максимальной длине штриха.

## 4. Ввод и state machine

Предлагаемые состояния:

```text
idle
pencilDrawing(activeStroke)
pencilErasing(gesture)
fingerPanning(startCamera, touchID)
pinching(startCamera, twoTouchIDs)
longPressCandidate(anchor, initialCamera)
blockedUntilTouchesEnd
paletteOpen(anchor)
```

Фактический набор touch IDs ведётся отдельно от текущего инструмента; нельзя считать `isPrimary`/порядок callbacks моделью multi-touch.

### Правила переходов

| Событие | Действие |
| --- | --- |
| Pencil began на свободном canvas | Новый active draft / eraser / pan в зависимости от инструмента |
| Pencil real samples | Добавить coalesced реальные точки; заменить predicted tail |
| Pencil ended | Убрать predictions, добавить финальную реальную точку, завершить draft |
| `touchesCancelled`, rotation/resize, resign active | Отменить active draft, убрать predictions, сбросить gestures; не отправлять create |
| Finger во время Pencil gesture | Игнорировать до окончания жеста; камера не двигается от ладони |
| Pencil began во время finger navigation | Остановить навигацию, зафиксировать камеру, заблокировать оставшиеся пальцы и начать Pencil gesture |
| Один finger без Pencil gesture | Кандидат long press, затем pan при движении |
| Второй finger | Отменить long press; pinch/pan по двум ID |
| Один finger остался после pinch | `blockedUntilTouchesEnd`, новый pan только после полного отпускания |
| Третий finger | Не участвует в текущем pinch; не переключать пару произвольно |
| Long press 500 ms, движение ≤10 pt | Восстановить начальную камеру при микроперемещении, открыть палитру |
| Касание canvas при открытой палитре | Только закрыть; этот touch не начинает рисунок |
| Открытие палитры/смена инструмента во время draft | Отменить незавершённый штрих, не отправлять частичный create |

### Рисование пальцем (20.11.2026)

Без Apple Pencil (и на iPhone) пальцы рисуют, иначе приложение было бы только просмотрщиком. Режим `FingerDrawingPolicy`: явный выбор «Рисовать пальцем» в меню `⋯` (только iPad) → иначе пальцы рисуют, пока не встретился первый Pencil touch и пока система не просит Pencil-only (`UIPencilInteraction.prefersPencilOnlyDrawing`). Первый Pencil в автоматическом режиме один раз показывает уведомление и навсегда (флаг `pencilSeen` в UserDefaults) возвращает Pencil-first. Режим фиксируется на первом пальце жеста и не меняется до отпускания всех пальцев.

| Событие (режим пальца) | Действие |
| --- | --- |
| Один finger | Сразу начинает штрих (как Pencil); кандидат long press |
| Второй finger ≤250 ms после первого | Бросить штрих, оба пальца — pinch/pan (`FingerGesture.pinchGrace`) |
| Второй finger позже | Игнорировать до отпускания всех пальцев; штрих продолжается |
| Long press 500 ms, движение ≤10 pt | Бросить штрих (пока точка), открыть палитру |
| Pencil began | Pencil побеждает: бросить штрих пальца, пальцы до отпускания ничего не делают |
| Условия не приняты | Штрих не начинается; лист условий — когда палец явно рисует (>10 pt) или тап; pinch не мешает |

Порог 500 ms / 10 pt наследует web UX и проверяется на устройстве. UIKit navigation recognizers должны принимать только direct touches и не отменять Pencil touches; одновременное распознавание pan/pinch задаётся явно. Hover не является началом рисования. При VoiceOver не перехватывать системную touch exploration бездумно: управление через accessibility actions и системные escape/activate должно оставаться доступным.

### Реальные и предсказанные точки

- Использовать `UIEvent.coalescedTouches(for:)`, дедупликацию по timestamp/position; не добавлять отдельно ту же исходную touch второй раз.
- Predicted touches существуют только для текущего кадра preview. При следующем real event полностью заменяются, при cancel/end удаляются. Не попадают в outbox, bbox, undo или server payload.
- Estimated-property updates не должны менять уже завершённый draft; pressure/tilt/roll в v1 не влияют на видимую линию.
- После sampling применять веб-совместимый bounded append: не добавлять точный дубль, обычный минимум расстояния 0.75 world units, финальную точку сохранять; при 2000 точек прореживать весь путь с сохранением концов, а не отрезать хвост.
- Пересборка preview допустима при decimation; после finalize payload замораживается навсегда. Нельзя заново фильтровать точки после reconnect.
- Before enqueue сохранять консервативную JSON byte-проверку всего `stroke.create` с request envelope ≤128 KiB, points/style/finite/world/extent limits. Перед send дополнительно проверять bytes фактически выбранного codec. MessagePack не разрешает повысить лимит 2000 points или менять payload после сохранения в journal; сервер остаётся окончательным валидатором.
- Если stroke не помещается по bytes, детерминированно уменьшить число точек до enqueue и обновить final preview; если всё равно недопустим — явная ошибка. Автоматически резать на несколько create в v1 не будем: это меняет opacity и undo semantics.

## 5. Pencil Pro и доступ к инструментам

Статус (18.11.2026): реализованы tap и squeeze через `PencilCommand` (`Input/PencilActions.swift`): switchPrevious — предыдущая форма кисти; showColorPalette, showInkAttributes и showContextualPalette открывают или закрывают всю палитру. Палитра привязывается к hover pose, иначе к последнему касанию пером, иначе к центру. switchEraser открывает палитру, пока нет ластика: на iPad squeeze по умолчанию «Ластик» (`preferredSqueezeAction = 1`), и no-op выглядел как неработающий жест; runSystemShortcut, ignore и неизвестные значения — no-op. Hover preview ещё не реализован. Secondary click принимает только `indirectPointer`: раньше короткий тап пером открывал палитру и отменял точку.

На canvas устанавливается `UIPencilInteraction`. Используются современные delegate callbacks `pencilInteraction(_:didReceiveTap:)` и `pencilInteraction(_:didReceiveSqueeze:)`, доступные с iPadOS 17.5, то есть ниже текущего deployment target.

### Предпочитаемые действия

Оба жеста читают соответствующий `preferredTapAction` / `preferredSqueezeAction`, а не имеют жёсткую функцию независимо от Settings:

| Preferred action | Поведение приложения |
| --- | --- |
| ignore | Ничего не делать |
| switchEraser | Сохранить предыдущий drawing tool и переключить кисть/ластик |
| switchPrevious | Переключить текущий и предыдущий поддерживаемый инструмент |
| showColorPalette | Открыть секцию цвета контекстной палитры |
| showInkAttributes | Открыть width/opacity/форму |
| showContextualPalette | Открыть полную палитру |
| runSystemShortcut | Не дублировать системный shortcut своим действием |
| неизвестное будущее значение | Безопасный no-op, не падать и не менять рисунок |

Для squeeze выполнить команду ровно один раз на `.ended`; `.began/.changed` можно использовать только для временной визуальной реакции, `.cancelled` очищает её без команды. Отдельный быстрый жест может прийти сразу с `.ended`.

Anchor палитры: `hoverPose.location` → последний достоверный Pencil/hover point → центр доступной области. Проверять актуальность координаты после resize и ограничивать safe area/клавиатурой. Отсутствие pose является штатным случаем.

Hover через `UIHoverGestureRecognizer` показывает footprint текущей кисти с учётом zoom и `UIPencilInteraction.prefersHoverToolPreview`; не добавляет точки. Наконечник chisel остаётся под -45° независимо от roll. У spray — outline области распыления, не новые случайные частицы, способные менять результат. `prefersPencilOnlyDrawing` учитывается автоматическим режимом рисования пальцем (см. выше).

Гаптический feedback — необязательная полировка после проверки доступного публичного API и device UX; не часть корректности жестов, не вручную дублировать системную отдачу squeeze.

### Палитра и альтернативные команды

SwiftUI overlay/popover, а не постоянный toolbar. Сохранить anchor при повороте, выполнить clamp вместо закрытия. Подписи локализованы через String Catalog. Цвета: `#202020`, `#E46C60`, `#E9AF59`, `#69A27F`, `#7195D0`, `#AD8ACB`, плюс произвольный RGB без неоговорённого alpha в color picker. Статус (18.11.2026): системный `ColorPicker` (`supportsOpacity: false`: сетка, спектр, ползунки, пипетка по экрану) переводит выбор в sRGB-байты с clamp; ряд «Recent colors» — до 7 своих цветов, которыми реально начинали штрих, новые первыми, без пресетов, в `UserDefaults` только в live-приложении. Палитру можно перетаскивать за заголовок; позиция ограничивается экраном (`PaletteLayout`).

Команды: long press, secondary click, accessibility action «Инструменты», keyboard context menu/Shift+F10, ⌘Z для undo. Accessibility entry у canvas доступен VoiceOver, но не рисует постоянную видимую кнопку. Стандартный accessibility escape закрывает палитру. Доступность на физическом iPad проверяется отдельно от наличия accessibility labels.

## 6. Геометрия и hit-test

Одна чистая геометрическая модель обслуживает Metal, bounds, fixtures и hit-test; GPU не решает ownership.

| Форма | Построение | Hit-test |
| --- | --- | --- |
| round | Прямоугольник каждого сегмента + круг radius width/2 в каждой точке | Расстояние до сегмента/точки с учётом радиуса |
| square | Прямоугольники сегментов, square caps, bevel joins; точка — осевой квадрат | Те же caps/polygons, не круглая аппроксимация |
| chisel | Наконечник -45°, длина width, толщина max(1,width/6); convex hull двух соседних footprints | Тест реальных sweep polygons |
| spray | Детерминированные circle instances по текущему web-алгоритму, без legacy-ветки | План: расстояние до реальной частицы, не всего диска width |

- Bbox padding: round/spray `width/2 + 1`, square/chisel `width/sqrt(2) + 1`; не обрезать геометрию по world limit после расширения.
- Spray: FNV-1a по lowercase UUID, xorshift32 с wrapping UInt32, fallback seed `0x9e3779b9`; вычисления centers/particles в Double с тем же порядком операций.
- Решение владельца 18.11.2026: максимальный диаметр частицы **1 world unit вместо 2.5**, включая все сохранённые штрихи, без обратной совместимости. Как в текущем `src/brush-geometry.ts`: radius `max(0.35, min(0.5, width/20))`, диаметр 0.7–1. При zoom=1 это 1 CSS px / 1 UIKit pt максимум, не один физический пиксель; при zoom частицы масштабируются с холстом. Spread `max(0, width/2 - radius)` использует новый радиус; seed, число частиц и шаг прежние. Дополнительных wire-полей, версии кисти или миграции journal нет. Native spray и pinned web fixtures уже используют этот контракт; будущий eraser hit-test обязан использовать те же частицы.
- Step `max(1,width/4,totalLength/2047)`, ≤2048 stamps, ≤48 частиц/stamp, ≤98304 particles/stroke. Trig не обещает побитовую одинаковость между платформами; проверять численный допуск и визуальный результат.
- Стиль brush захватывается в начале, UUID назначается до первого preview, поэтому seed preview/ack/snapshot одинаков.
- Допуск eraser 4 экранных pt переводится в world через zoom. Принимаются только кандидаты `own`; чужая геометрия не скрывается оптимистически.
- Предлагаемое поведение eraser sweep: удалить все пересечённые собственные штрихи, дедуплицируя ID за жест, с bounded delete queue. Траектория ластика проверяется между событиями, чтобы быстрое движение не пропускало тонкие штрихи.
- Для M1 достаточно ограниченного обхода видимых extents; M4 добавляет пространственный индекс. Не раскладывать огромный bbox по неограниченному числу grid cells: длинные штрихи требуют overflow bucket/дерева.

## 7. Metal pipeline: сначала корректность

### Кадр

1. Получить latest immutable scene snapshot, camera и preview.
2. Отобрать пересекающие viewport stroke extents; подтвердить наличие geometry handles.
3. Отрисовать подтверждённое состояние по возрастанию `seq`.
4. Поверх — неподтверждённые локальные штрихи по local ordinal, исключая ID, уже видимые из собственного event/ack.
5. Последним — active real + predicted preview и hover indicator.
6. Present drawable; completion handler освобождает только ресурсы завершившегося command buffer.

На M1/M2 допустим direct rendering видимого множества, чтобы проверить правильность до тайлов. Pending не встраивать в confirmed tiles: его положение в глобальном порядке ещё неизвестно.

Реализовано (M4): подтверждённые штрихи запекаются в тайлы 512 px. Кадр — один проход: копия видимых тайлов по целым пикселям snapped-камеры, затем overlay (pending и volatile) и preview. Каждый штрих при этом рисуется одним проходом на цель через framebuffer fetch: покрытие с `max`, композит opacity и сброс покрытия — отдельными draw. Где fetch нет (iOS Simulator), остаётся двухпроходный путь.

### Прозрачность — один раз на штрих

Нельзя просто рисовать все сегменты с alpha=opacity: круги, прямоугольники и частицы пересекаются и затемняют один штрих многократно.

Базовый корректный путь:

1. Очистить переиспользуемую coverage mask в ограниченном rect/тайле.
2. Нарисовать всю геометрию одного логического штриха в маску, собирая объединение покрытия, а не суммы alpha. Базовый кандидат — renderable `r8Unorm` с blend operation `max`, при поддержке 4x MSAA для polygon edges; круги — instanced quads с analytic/SDF coverage. Проверить sample-count/format capabilities до создания pipelines.
3. Resolve при MSAA, затем один composite с `alpha = coverage * stroke.opacity`, `rgb = color * alpha`.
4. Premultiplied source-over: source factor `one`, destination `oneMinusSourceAlpha`.

Сегментированные/batched части одного stroke используют одну маску и единственный composite. Не применять opacity на batch отдельно. Не читать texture, являющуюся текущим render target. На M1 render tests должны доказать self-overlap и edge quality, прежде чем выбирать fast paths для непрозрачных штрихов.

Начальный цветовой профиль — стандартный sRGB, без HDR/P3 ink. Для совпадения с web-числами предполагается numeric sRGB-like source-over в `bgra8Unorm` и явно заданное sRGB представление слоя; автоматическое linear-light blending через `_srgb` attachments не включать без fixture-сравнения. Точный выбор drawable/colorspace закрепляется render test: середина полупрозрачной цветной линии должна совпадать с сайтом, небольшое расхождение AA на краях допустимо. Никакого тёмного canvas в dark mode.

### Планирование кадров

- Запрашивать high refresh через доступные public frame-rate controls с проверкой OS/device; нельзя полагать, что `preferredFramesPerSecond = 120` гарантирует выдачу 120 Hz.
- В активном drawing/pan/pinch обрабатывать кадры в ритме display; события ввода только обновляют latest state и invalidation.
- В покое `MTKView` paused, draw по invalidation; очередь rebuild может временно будить следующие кадры.
- При нехватке drawable/in-flight slots пропустить кадр, сохранить latest state и снова запросить; не ждать GPU синхронно на main thread.
- 2–3 in-flight frame resources, без перезаписи буферов до GPU completion. Completion callbacks не мутируют UI напрямую.
- Low Power / thermal pressure могут снизить целевую частоту и prefetch; геометрия, порядок и opacity не меняются.

## 8. Тайлы, кеши и деградация

Вводятся после baseline-профилирования, не являются зависимостью первого общего штриха.

### Кеши

1. CPU geometry LRU: immutable prepared data по `(strokeID, geometryVersion)`, размер в bytes.
2. GPU geometry LRU: buffers/instances, стоимость и in-flight lifetime; освобождение после completion.
3. Raster tile LRU: world-aligned texture с revision/scale/maxSeq, strokes extents и dirty region.

Предлагаемый tile: внутренние 512×512 drawable pixels + 2 px gutter для фильтрации/AA. На screen композитится только внутренняя часть; границы считаются согласованно, чтобы шов не удваивал opacity. Во время pinch масштабы с шагом √2, после ~180 ms покоя rebuild в точном zoom×drawable scale.

### Инвалидация

- Добавление stroke с `seq > tile.maxSeq`: можно дорисовать поверх, если tile актуален и bounded append queue не переполнена.
- Более старый seq, удаление, hide/unhide, замена snapshot или eviction scene objects: dirty соответствующих тайлов, rebuild по отсортированному множеству.
- Операция `hidden` делает старый tile непригодным немедленно. Пока rebuild не готов, dirty область рисуется direct или закрывается актуальным fallback; нельзя показывать удалённый штрих до конца очереди rebuild.
- ACK pending переводит ID в confirmed без двойного изображения; возможна корректная перестановка по seq.
- Pan не пересобирает mesh и не перерисовывает готовые неизменённые тайлы.
- Разные LOD fallback выбираются непересекающимися screen regions; не наслаивать два масштаба одного рисунка. Старый tile нельзя использовать, если его revision включает уже удалённые объекты.

### Начальные бюджеты для M4

- Rebuild CPU scheduling: примерно 2 ms на 120 Hz / 4 ms на 60 Hz, уточнить по capture. GPU budget измеряется отдельно; CPU timer не измеряет завершение GPU.
- Tile LRU: до 64 MiB; geometry GPU cache: до 48 MiB. Это лимиты кешей, а не total GPU memory: отдельно учесть drawable, coverage/MSAA, command buffers и transient uploads.
- Отдельные CPU лимиты на decoded strokes/points/bytes, staging и geometry; начальные count caps 20000 strokes / 1000000 points для одной полной области — верхние страховки, не гарантированно допустимый memory footprint.
- Параллельно живут old + staging, поэтому общий byte budget проверяется на union, не разрешается удвоение без учёта. Pending и in-flight resources тоже входят в общий учёт.
- Тяжёлый spray генерировать/загружать порциями внутри одной coverage mask, если целый buffer не помещается. Нельзя незаметно уменьшать число частиц подтверждённого штриха.
- Memory warning: удалить offscreen tile/geometry кеши, отменить prefetch, снизить временные бюджеты; outbox и активный draft не выбрасывать молча.
- Если полная область превышает лимит канонической сцены, выставить `incomplete/degraded`, прекратить бесконечные одинаковые resync, показать краткую ошибку и предложить через палитру приблизить/сменить область. Частичный набор не выдавать за полный snapshot.

## 9. Сеть и состояние сцены

### Transport

Codec, URLSession transport, application FSM и shared-world entry реализованы в [M2.3](progress/m2-shared-canvas.md). Пакет msgpack-swift exact 2.0.6 + mandatory preflight; lossless float32-shortening trusted output разворачивается в float64, входящий float32 запрещён. JSON-text round-trip нет. Corpus/Swift→frontend interop, настоящий dev backend/Postgres mixed-profile mutation smoke и native read-only production HTTPS/WSS проверены; physical iPad gate остаётся. Подробности — [M2.2](progress/m2-msgpack-transport.md).

Semantic journal хранит payload, не frames: unit test JSON→binary retry сохраняет UUID/geometry, environment/owner и одну undo запись. Keychain/storage namespaces не меняются вместе с wire profile.

- Production `wss://endlessdrawing.com/ws`, origin `https://endlessdrawing.com`; dev задаётся конфигурацией, не постоянным UI-переключателем.
- Один `URLSessionWebSocketTask` с явным разрешённым Origin. Negotiated mode предлагает `endless-drawing.msgpack.v4`, `…v3`, `…v2`, затем `endless-drawing.json.v1`; выбранный профиль проверяется через delegate до hello. v4: visible-first snapshot (`visible_bounds`); v3+: cached subscribe (manifest + fetch недостающих), только внутри соединения после завершённого snapshot; reconnect/resync/fallback — всегда полный snapshot. Нативная адаптация URLSession, legacy deployment mode и rollout gates — [transport-evolution.md](transport-evolution.md). Origin не является authentication; ownership задаёт secret.
- Локальный endpoint `ws://127.0.0.1:3000/ws` подходит simulator на Mac; на физическом iPad нужен LAN-адрес Mac/HTTPS-стенд, разрешённый Origin и при необходимости Local Network permission. Loopback iPad не является Mac.
- ATS/dev exceptions — точечные и только Debug, Release не получает blanket `NSAllowsArbitraryLoads`. Настоящий dev TLS предпочтительнее; никакого trust-all delegate.
- Не следовать неожиданному cross-host redirect с credentials; endpoint/Origin/identity привязаны к environment. Не логировать request headers, hello или raw frames.
- JSON v1 — один object в Text message, MessagePack v2 — один named map в Binary message. Один WS message может состоять из нескольких transport frames. Для JSON сохранить текущий receive cap 4 MiB, для v2 — 256 KiB до decode плюс structural budget и ≤8192 points/chunk. Client payload ≤128 KiB в обоих профилях. Codec не угадывается по bytes; компрессия отдельно и пока не включается.
- Serial send queue объединяет hello/subscribe/mutations/ping, имеет byte/count bounds. При backpressure ставит на паузу outbox, а не копит память; канонические входящие события не теряются, при overflow disconnect + resnapshot.
- Ping/pong проверить с URLSession на реальном backend, а не предполагать browser-like поведение. Предлагаемый idle ping ~20 s в foreground, timeout → reconnect; не создавать storm параллельно штатному heartbeat сервера.

### Connection state

```text
stopped → connecting → selectingProfile → awaitingHello → loadingSnapshot → live
               └────────── ошибка/timeout ──────────→ backingOff → connecting
любое active → background/stopped (outbox остаётся)
```

`hello.ack.protocol_version` должен совпасть с выбранным профилем: 1 для JSON, 2 для MessagePack. Пустой selected profile при предложенных subprotocols — ошибка, не auto-legacy retry. Optional spawn применять только если нет восстановленной камеры и пользователь ещё не перемещал холст; reconnect не телепортирует. До hello ack запрещены subscribe/create/delete.

Начальные таймеры: connect/hello client watchdog 8 s, ack 12 s, snapshot целиком 35 s; серверные defaults — hello 5 s, operation 10 s, snapshot 30 s. Snapshot deadline не продлевается бесконечно каждым chunk. При config mismatch уточнять среду, не маскировать таймаутами.

Reconnect: exponential backoff с jitter, от ~0.5 до 10 s. `NWPathMonitor` — подсказка для wake, не доказательство доступности сервера. Отменённая старая task не может закрыть новое соединение: callbacks сравнивают generation.

### Подписки

- Одна область на соединение. Новые `subscription_id` на каждую попытку, late frames старого ID игнорируются.
- Prefetch до 3× видимого span, но максимум 30000 по каждой оси и clamp world. Переподписка до выхода из загруженной области, с coalescing latest bounds и интервалом ≥260 ms (ниже 5/s).
- При pan не отправлять subscribe на каждый кадр. Согласовать camera bounds, фактически отправленные bounds и last completed coverage отдельно.
- Не пытаться восстановить события через `last_seq`: delete не создаёт нового seq.
- Приняты следующие транспортные этапы: authoritative manifest + missing geometry, затем visible-first внутри snapshot. Они требуют отдельного согласованного контракта следующей версии; не добавлять token/fetch/visible_bounds в текущий v2. См. [нативный план транспорта](transport-evolution.md).

### SceneStore

Хранит раздельно:

- `confirmed`: последний завершённый авторитетный snapshot области и последующие live события;
- `staging`: новый snapshot до end;
- `pendingCreates`: локальные immutable drafts, для которых операция ещё не закрыта;
- `hidden`: собственные удаления/отменённые create, ожидающие разрешения;
- bounded tombstones и overlays для ack, пришедших вне snapshot-порядка.

Пересмотрено для быстрой первой отрисовки: валидные server records из staging показывать по мере готовности geometry, поверх bounded stale/confirmed display с дедупликацией UUID и server seq order. Отсутствующие IDs удаляются только при snapshot.end, который атомарно заменяет authoritative membership. Известные tombstones/hidden не ждут end. При отмене уже показанное может остаться bounded stale cache, но не доказательством complete области. Empty/fully-cached end завершает loading/deadline даже без изменений render set. Это progressive display, не обещание server-side visible-first до следующего контракта.

ACK не scoped текущей областью: свой stroke может подтверждаться уже за экраном. Подтверждение хранится в operation/undo history, а в scoped rendering попадает только если пересекает новую область. Не прибавлять все offscreen acks к авторитетному snapshot навсегда.

Создание во время staging: локальные ack-overlay записи сверяются по UUID и пересечению; delete/tombstone имеет приоритет над запоздалым snapshot/ack. `stroke.created` может прийти раньше ack: показать canonical stroke один раз, скрыть дублирующий pending preview, но не терять operation journal до разрешения результата. Snapshot absence не означает глобальное удаление ID или потерю права ownership.

Ограниченные tombstones относятся к generation/event stream; не вытеснять защиту от resurrection молча, если ещё возможен поздний ответ. При исчерпании лимита завершить generation, получить новый snapshot и согласовать pending через идемпотентные операции.

### Безопасность контента (App Review 1.2, 19.11.2026)

Контракт — backend `docs/protocol-v5-safety.md`, продуктовый проект — frontend `docs/ugc-safety.md`.

- Предлагается `endless-drawing.msgpack.v5` первым; в v5 у каждого штриха обязательное поле `author` (22 символа base64url, метка автора для этого зрителя), в v1–v4 оно запрещено.
- Согласие с `/terms` спрашивается в live-приложении один раз на версию (`CanvasModel.termsVersion`) при первом касании Pencil для рисования; просмотр холста не блокируется. Тесты и превью без `UserDefaults` не спрашивают.
- Палитра: меню `⋯` — «Пожаловаться…», «Показать скрытое» (если есть), условия, почта поддержки.
- Режим жалобы: тап пальцем или Pencil выбирает чужой штрих (`StrokeHitTest`, верхний по seq, допуск 12 pt), пальцы по-прежнему двигают холст, рисование выключено; выбранное обведено пунктиром. Лист причины + «Скрыть всё от этого автора» (по умолчанию включено).
- После отправки выбранное и при блоке все штрихи автора сразу скрываются локально (`HiddenContent` в `UserDefaults`, только устройство) и фильтруются в `rebuildSharedScene`; `stroke.report` уходит из `WorldSession` по одному на v5-соединении (в памяти, повтор при `rate_limited`, сброс при прочих ошибках). `banned` для create/report → `WorldIssue.banned`, рисование выключено.

## 10. Outbox, retries и undo

### Persist-before-send

1. Finalize: убрать predictions, проверить points/style/bounds/message bytes.
2. Назначить local ordinal и сохранить immutable payload в journal. До завершения записи не отправлять и не объявлять переживающим restart; на экране можно удерживать финальный preview.
3. После успешной записи переместить в pending и передать mutation scheduler.
4. Перед первой send сохранить признак `mayHaveBeenSent = true`. Crash между этой записью и send даёт лишний безопасный retry, обратный порядок создаёт риск потерянного commit.
5. Отправить attempt с новым request_id, тем же stroke UUID и точным normalized payload.
6. ACK → durable транзакция закрытия операции/обновления undo → публикация resolved state. Crash до записи допускает повтор, который безопасен.

Предлагаемое хранение — небольшая versioned atomic journal snapshot в Application Support, обновляемая serial executor через temp+replace; сохраняется payload, не GPU cache. Максимум 64 неразрешённых create, 256 delete и общий disk cap 16 MiB. При полном журнале остановить новые мутации и кратко сообщить причину; не вытеснять неизвестно закоммиченные операции. Для более частой нагрузки формат можно сменить на транзакционный SQLite после измерений, сохранив интерфейс.

Journal проверяет schema/version/размеры/identity reference/environment и invariant dependencies при загрузке. Corruption не превращается в «пустая очередь, всё сохранено»: сохранить bounded quarantine для диагностики без секрета и явно сообщить о невозможности восстановления. Не обещать защиту от физического отказа storage только за счёт atomic replace.

### Неопределённый результат

Timeout/disconnect до ack не означает отказ. Вернуть attempt в очередь, тот же UUID и payload; request_id новый. Mutation scheduler: ≤5 create и ≤20 delete в окне 1100 ms; subscribe/ping также учитываются в общем лимите frames. Все deadlines считаются monotonic clock.

`rate_limited`/`internal_error` — bounded backoff retry, операция не удаляется. `id_conflict`/validation/forbidden — terminal branch с кратким сообщением; при подозрении на рассогласование ownership получить fresh snapshot. `stroke_deleted` — не пытаться воскресить. Protocol/version errors не запускают быстрый бесконечный retry; нужен backoff и доступная диагностика.

### Undo и отмена pending

- Local ordinal фиксирует порядок рисования; arrival order ack не должен переставлять undo history.
- Если create гарантированно не отправлялся, undo удаляет его из journal/очереди без сетевой мутации.
- Если `mayHaveBeenSent`, пометить cancelled и скрыть preview; разрешить idempotent create, затем отправить delete того же ID. Нельзя просто забыть потенциально успешный commit.
- Delete dependency выполняется после разрешения create. Повторный `stroke_deleted` завершает отмену без resurrection.
- Для confirmed own stroke undo — обычный delete; optimistic hide, при terminal отказе снять hide только если нет authoritative delete/tombstone.
- История до 500 локальных подтверждённых ID, без дублей от ack/event/retry. Свои strokes, встреченные только в snapshot, не добавлять автоматически как новые действия undo.
- Delete ack / событие удаления очищают сцену и нужную history entry идемпотентно. `not_found` для своего pending delete можно считать отсутствием объекта; `forbidden` не считать успехом.
- Нет redo в первой версии: удалённый UUID нельзя воскресить повторным create.

## 11. Хранение, identity и жизненный цикл

### Identity

- Секрет: `SecRandomCopyBytes`, 32 bytes, base64url без padding; генерируется один раз на identity/environment, только при достоверном `itemNotFound`.
- Keychain accessibility `WhenUnlockedThisDeviceOnly`, без synchronizable/iCloud. Не использовать UserDefaults, URL query, analytics или логи.
- Ошибка protected data/Keychain не эквивалентна отсутствию identity: дождаться unlock, не генерировать нового владельца поверх старого outbox.
- Journal ссылается на несекретный identity ID, не содержит session_secret. При mismatch/недоступности ключа очередь не отправляется с другим secret.
- Dev/prod имеют раздельные namespace, journal и camera. Смена host не переносит pending автоматически. Выбранный transport profile не меняет identity. Префикс `v1` в Keychain account и journal path — storage schema, а не JSON wire version: не заменять его на `v2` из-за MessagePack.
- Backup: связанные identity-dependent журналы исключены из backup, защищены file protection, согласованной с unlocked key. Не обещать ownership после переустановки/переноса устройства; Keychain persistence после uninstall зависит от системы, это не recovery contract.
- Reset identity не добавлять как безобидную кнопку: при будущем появлении требуется предупреждение о потере delete rights и разрешение pending операций.

### Локальные данные

| Данные | Хранилище | Правило |
| --- | --- | --- |
| Секрет | Keychain | Только hello, device-only |
| Preferences / camera | UserDefaults, versioned | Валидация/значения по умолчанию при повреждении |
| Outbox / undo | Защищённый atomic journal | Persist-before-send и восстановление |
| Общий мир | RAM текущей области | После запуска fresh snapshot |
| Mesh / raster tiles | RAM/GPU disposable | Не часть документа и не доказательство сохранения |

### Scene lifecycle

- Первая версия — одно активное canvas window; не создавать независимый WorldSession при каждом SwiftUI body update.
- На resign active отменить незавершённый gesture, снять predictions, остановить frame loop. Уже завершённые операции сохранены до send, поэтому не полагаться на последний background callback для сохранения.
- Socket/receive/send tasks остановить, не пытаться рисовать и держать бесконечный background WebSocket. Короткое завершение уже начатой journal transaction допустимо через системно ограниченную background task.
- На foreground/unlock восстановить identity/journal, открыть новую generation: hello → subscribe → snapshot; выполнять ограниченный replay outbox после hello, с указанной дедупликацией/race semantics.
- Resize/rotation/Stage Manager обновляют viewport/drawable и bounds, отменяют активный draft; completed pending остаются. Memory warning не стирает ownership/outbox.

## 12. Наблюдаемость и ошибки

OSLog/signposts с категориями input, geometry, frame, tiles, connection, snapshot, journal. Допустимы счётчики, длительности, byte cost, state transitions и безопасные коды. Не писать секреты, hello, raw frames, points пользователей, production payload dumps; debug fixtures синтетические.

Метрики: input-to-submit и отдельно доступная оценка submit-to-present, CPU encode/build p50/p95, GPU duration, frame pacing/missed frames, resident/cache bytes, tile dirty backlog, reconnect/resync/ack latency и outbox depth. Clock domains GPU/CPU/display не смешивать как одну «точную задержку Pencil».

Ошибки делятся на transient (retry), terminal mutation (rollback/сообщение), protocol/configuration (остановка/ограниченный reconnect), local storage (не отправлять несохранённое как recoverable) и renderer resource pressure (освобождение кешей/direct fallback). Если Metal недоступен, не подменять приложение WebView; показать краткую доступную ошибку и возможность повторить, подробности в безопасной диагностике.

## 13. Предлагаемая структура файлов

```text
Endless Drawing/
  App/                 EndlessDrawingApp, AppEnvironment
  UI/                  ContentView, ContextPalette, String Catalog
  Canvas/              CanvasViewController, CanvasRepresentable, CanvasCoordinator
  Input/               InputMachine, PencilInteractionController, SampleCollector
  Domain/              Camera, Stroke, Brush, Geometry, HitTest
  World/               WorldSession, SceneStore, SceneReducer, MutationScheduler
  Networking/          WebSocketTransport, WireDTO, WireValidation
  Persistence/         IdentityStore, OperationJournal, PreferencesStore
  Rendering/           MetalRenderer, GeometryBuilder, FrameScheduler
                       GeometryCache, TileCache, Shaders.metal
  Diagnostics/         Signposts, DebugSceneFixtures
Endless DrawingTests/  Unit, Contract, Fixtures
Endless DrawingUITests/
```

Это логические границы, не требование сразу создать десятки пустых файлов или отдельные packages. Сначала минимальный вертикальный срез, затем извлечение компонентов по реальным зависимостям. Текущий Xcode target использует filesystem-synchronized group: при добавлении test fixtures и generated artifacts проверить target membership, не включать test-only данные в Release bundle.
