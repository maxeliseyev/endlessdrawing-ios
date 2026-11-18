# M1 — первый локальный Metal-срез

## Статус

Реализован локальный прототип в Debug и Release, не завершён весь M1. Рисунки только в RAM, не отправляются на сервер и не переживают завершение процесса. После сообщения владельца о заглушке на iPad убран `#if DEBUG` вокруг canvas: обе конфигурации запускают один интерфейс. Предупреждение о локальном режиме остаётся в палитре. Это не offline fallback продукта и не готовность к публичному выпуску.

Изменения — рабочее дерево поверх `6b8c6c1`; исходная template-сборка проверена до замены SwiftData UI. Bundle ID, signing team, minimum iPadOS 18.6 и iPad-only сохранены. В `Configuration/Info.plist` явно отключён multiwindow; проверен результат сборки `UIApplicationSupportsMultipleScenes = false`.

## Что реализовано

- `Domain/Camera.swift`: Double world coordinates, pan, anchored zoom/pinch, clamp ±1e9 и 16–400%.
- `Domain/Stroke.swift`: immutable local round strokes, захват style в начале, bounded real samples/decimation, отдельный predicted tail, cancel/finalize.
- `Input/NavigationInput.swift`: один палец — pan, два — pinch/pan, фиксированная пара, блокировка остатка жеста и ладони во время Pencil.
- `Rendering/RoundGeometry.swift`: сегментные прямоугольники и круги caps/joins, локальные Float vertices относительно Double origin, serial worker actor вне UI thread.
- `Rendering/Shaders.metal` и `MetalRenderer.swift`: R8 coverage union через max blend, 4x MSAA при поддержке, circle SDF, единый premultiplied composite на stroke. Полупрозрачные self-overlap не затемняются повторно.
- Готовые локальные strokes рисуются в screen-sized cache; preview — поверх него. При pan/zoom/изменении документа cache перестраивается. Это ещё не world tile cache M4.
- GPU uploads завершённых strokes переиспользуются; camera-relative subtraction выполняется в Double до передачи GPU. До 3 in-flight кадров без ожидания GPU на main thread; renderer спит в покое и не рисует в background.
- `Canvas/CanvasViewController.swift`: UIKit Pencil/coalesced/predicted touches, finger navigation, long press, resize/cancel/lifecycle, async geometry и bounded local document (256 strokes / 100000 real points).
- `UI/ContextPalette.swift`: preset colors, width/opacity, локальный undo и reset view. Нет постоянного toolbar.
- Палитра также доступна через secondary click, ⌘K / Shift+F10, accessibility custom action; есть EN/RU String Catalog. Физическая keyboard/VoiceOver-приёмка ещё нужна.
- Удалён шаблонный Item/SwiftData container. Локальные strokes не выдаются за server-confirmed объекты.

## Фактические автоматические проверки

Окружение: Xcode 27.1 (`27A9275`), iPhoneOS/iPhoneSimulator SDK 27.1, официальный Metal Toolchain `27A266a`. Недостающий компонент установлен через `xcodebuild -downloadComponent MetalToolchain`.

| Проверка | Результат |
| --- | --- |
| Baseline исходного шаблона, Debug generic iOS Simulator, без подписи | PASS |
| Debug generic iOS device, без подписи | PASS; это компиляция, не запуск на устройстве |
| Release generic iOS Simulator, arm64/x86_64 | PASS; после исправления canvas доступен и в Release |
| Debug тесты, iPad Pro 11-inch M4 Simulator, runtime iOS 18.6 | 23 PASS |
| Повтор этих тестов на M4 Simulator, runtime с меткой iOS 27.0 | 23 PASS |
| После исправления: Debug + Release, M4 Simulator iOS 27.0 | 24 PASS в каждой конфигурации, включая запуск `MTKView` |
| После исправления: Release generic iOS device, без подписи | PASS; повторная физическая приёмка владельцем ещё нужна |
| После исправления мигания Pencil: Debug + Release, M4 Simulator iOS 27.0 | 27 PASS в каждой конфигурации |
| После исправления мигания Pencil: Release generic iOS device, без подписи | PASS |
| Swift strict concurrency + warnings as errors | PASS |
| Test scheme запрашивает `MTL_DEBUG_LAYER=1` | Во время test action; GPU shader validation на устройстве ещё не выполнена |
| Собранный scene manifest | Single-scene, `UIApplicationSupportsMultipleScenes = false` |

Состав 23 тестов:

- 4 camera: inverse mapping, anchor, zoom/world clamps, moving pinch midpoint;
- 8 input/navigation: predictions не сохраняются, stale/duplicate samples, decimation endpoints, invalid style/extent, fixed pair и blocked remainder;
- 3 geometry: веб-fixtures, translation invariance у ±1e9, invalid/empty input;
- 8 offscreen Metal: white background, self-overlap, independent strokes, undo/preview cache invalidation, camera invalidation, RGB/source-over, вертикальная ориентация, точность camera-relative dot.

`Fixtures/round-geometry.json` сгенерирован из frontend `75b59f179b65a2b4d0a69bd6710a4a6c51066a01`, содержит SHA256 исходников и 4 round cases. Скрипт: `tools/generate-round-fixtures.cjs`. Xcode-тесты читают готовый fixture из test bundle, Node при запуске тестов не нужен.

Служебные сообщения Xcode об отсутствии AppIntents dependency и parsing SDK build number встречались в логах инструмента. Ошибок Swift/Metal-компиляции или проваленных тестов нет. FPS, GPU time и Pencil-to-photon latency не измерялись; времена выполнения unit-тестов не являются performance-результатом приложения.

### Воспроизведение

Выбрать установленный iPad simulator UUID из `xcrun simctl list devices available`. Для текущего полного набора с Keychain нужен подписанный Simulator host; исходный M1 без Keychain допускал `CODE_SIGNING_ALLOWED=NO`. См. [M2.1](m2-foundation.md).

```bash
IPAD_SIMULATOR_ID='<UUID>'
xcodebuild -project 'Endless Drawing.xcodeproj' \
  -scheme 'Endless Drawing' -configuration Debug \
  -destination "platform=iOS Simulator,id=$IPAD_SIMULATOR_ID" \
  -derivedDataPath /tmp/endless-drawing-signed-tests \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- test

xcodebuild -project 'Endless Drawing.xcodeproj' \
  -scheme 'Endless Drawing' -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/endless-drawing-device \
  CODE_SIGNING_ALLOWED=NO build
```

Для текущего проекта с SPM warnings-as-errors заданы в собственных targets, не глобальным CLI override; причина — [M2.2](m2-msgpack-transport.md).

## Исправление запуска Release

Владелец запустил сборку на физическом iPad и получил сообщение «Подключение к общему холсту ещё не реализовано». Причина в коде — `ContentView` подменял весь canvas заглушкой при отсутствии `DEBUG`. Условие удалено; переключать конфигурацию ради локального рисования больше не нужно.

Добавлен `CanvasLaunchTests.rootContainsMetalCanvasInEveryBuildConfiguration`: проверяется настоящий UIKit hierarchy у SwiftUI root в видимом окне, в нём должен присутствовать `MTKView`. Тест выполняется вместе с исходными 23 проверками. Для тестирования Release используется `ENABLE_TESTABILITY=YES`, без изменения обычных release-настроек проекта. Готовый набор — 24 теста в 5 suites.

Запуск на iPad подтверждён владельцем, но исправленную сборку и ввод/жесты ещё нужно повторно принять на физическом устройстве. Сервер по-прежнему не подключён.

## Устранение мигания при отпускании Pencil

Владелец подтвердил рисование на физическом iPad и заметил краткое исчезновение штриха после поднятия Pencil. Причина: `ended()` очищал preview сразу, а `complete()` ждал асинхронной подготовки финальной геометрии; между ними renderer мог показать пустую область.

Исправлено для текущей круглой кисти:

- builder отмечает диапазоны mesh/circle buffers, соответствующие только реальным samples, до predicted tail;
- при завершении эти диапазоны синхронно передаются из preview в локальный документ, без новой тесселяции, upload или ожидания GPU на UI thread;
- predictions отбрасываются, а реальная геометрия остаётся видимой до атомарной замены на финальную;
- следующий штрих не затирает ещё финализирующийся; поздний preview не воскрешает отменённый/удалённый через undo ID.

Добавлены 3 регрессии: совпадение реального prefix с независимой тесселяцией (включая дубли точек), несколько кадров после отпускания до выполнения worker, быстрые последовательные strokes с undo и поздней финализацией. GPU-тесты вызывают реальный `CanvasViewController.complete`, проверяют отсутствие blank frame, predicted ink и повторного затемнения opacity. Всего 27 тестов проходят в Debug и Release; Release device build без подписи также проходит. Владелец затем повторно проверил сборку на iPad и подтвердил, что мигание устранено и рисование работает.

## Что ещё не сделано

- Полная приёмка ладони/long press/keyboard/VoiceOver, rotation/lock/Stage Manager и memory pressure; базовое рисование и отсутствие мигания уже подтверждены владельцем.
- GPU capture, frame pacing, latency и thermal/battery measurements на iPad. `preferredFramesPerSecond = 120` — запрос, не гарантия.
- Double-tap, squeeze, hover и полное управление Pencil Pro; это M3, не имитируется наличием обычного Pencil input.
- WS/Origin handshake, Keychain, outbox, сохранение camera/preferences и восстановление после crash.
- Square/chisel/spray, eraser, серверный undo, произвольный RGB picker/HEX.
- World tiles, spatial index, geometry LRU и dense-scene degradation M4.
- Подпись и повторная проверка исправленного device build, затем TestFlight.

После подтверждения исправления владельцем начат [M2.1](m2-foundation.md): протокол, identity и durable operations. Следующий срез — transport/session и подключение общего мира, сохраняя gate поддержки всех серверных форм до внешней раздачи клиента.
