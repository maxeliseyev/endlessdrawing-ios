# Endless Drawing — iPad

Нативный клиент общего бесконечного холста для iPad и Apple Pencil Pro.

## Основа

- SwiftUI для интерфейса, UIKit для Pencil/finger input, Metal / MetalKit для рендера.
- Общий мир с веб-клиентом: `wss://endlessdrawing.com/ws`, negotiated MessagePack v2 / JSON v1.
- Keychain для секрета владельца; без регистрации и отдельного аккаунта.
- Только холст при запуске; инструменты и состояние подключения — в контекстной палитре.

## Текущий статус

**M2.3: Canvas подключён к общему миру в Debug и Release.** Snapshot загружается постепенно, приходят live updates. Finalized stroke сначала сохраняется в локальную очередь, затем отправляется; ack подтверждает результат. При потере соединения pending сохраняется и повторяется с прежним UUID. Undo использует серверное удаление собственных действий, включая компенсацию unknown create.

Поддерживаются round/square/chisel/spray, максимум частиц спрея — 1 world unit без legacy 2.5. Zoom **8–400%**. Camera, ownership, outbox и undo сохраняются между процессами; brush settings пока нет. До успешной локальной записи draft остаётся только в RAM, о сбое записи сообщается отдельно; pending не выдаётся за server-saved.

**Проверено:** 104 обычных автоматических теста плюс 3 opt-in network gates. Debug на Simulator 18.6/27.0, Release на 27.0 и unsigned Release device build; отдельные native read-only production WSS и настоящий dev backend/Postgres с binary/JSON, ownership, idempotency и undo. В production тестовых рисунков не создавали. Подробности: [M2.3](docs/progress/m2-shared-canvas.md).

Владелец ранее подтвердил локальное рисование на iPad и устранение Pencil-lift flicker. **Подключённую сборку ещё нужно принять на физическом iPad.** Полные Pencil Pro gestures, eraser, GPU/performance/thermal matrix, тайлы и manifest/visible-first пока не завершены. Нет обещания 120 FPS на любой плотности сцены.

## Документация

1. [План разработки](docs/implementation-plan.md).
2. [Архитектура](docs/architecture.md).
3. [Проверки и физическая приёмка](docs/validation.md).
4. [M2.1: identity и journal](docs/progress/m2-foundation.md).
5. [M2.2: MessagePack и transport](docs/progress/m2-msgpack-transport.md).
6. [M2.3: подключение Canvas](docs/progress/m2-shared-canvas.md).
7. [Эволюция транспорта](docs/transport-evolution.md) — следующий native manifest/cache и visible-first.

## Запуск

Открыть `Endless Drawing.xcodeproj`, выбрать схему **Endless Drawing** и iPad. Обычный запуск подключается к опубликованному миру. В случае сети/хранилища нет скрытого переключения в RAM-only прототип.

- Pencil рисует; один палец перемещает, два — перемещают и масштабируют.
- Удержание пальцем 500 ms открывает палитру: форма кисти, цвет, width, opacity, undo, сброс вида, состояние соединения и Retry.
- Альтернативы: secondary click, ⌘K / Shift+F10 и accessibility-действие «Инструменты»; ⌘Z — undo.
- Пальцы намеренно не рисуют. Double-tap, squeeze и hover Pencil Pro ещё впереди.
- Секрет владельца device-only. Переустановка/смена iPad не гарантирует восстановление права удаления.

**Тесты — ⌘U.** Они используют явную dependency injection и не открывают production автоматически. Opt-in network gates описаны в отчёте M2.3. Нужен подписанный Simulator host (`CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-`) для настоящего Keychain. Для Release tests — `ENABLE_TESTABILITY=YES`.

SPM загружает pinned `msgpack-swift` 2.0.6. Warnings-as-errors уже заданы собственным targets, не передавать глобальный override зависимостям. Нужен Xcode 27.1 с Metal Toolchain; при отсутствии компонента: `xcodebuild -downloadComponent MetalToolchain`.

Геометрические fixtures обновляются явно: `node tools/generate-round-fixtures.cjs` и `node tools/generate-brush-fixtures.cjs`. Генераторы используют соседний frontend/TypeScript; обычные Xcode-тесты от Node/frontend не зависят.

## Связанные проекты

- Веб-клиент: [`../endless-drawing-frontend`](../endless-drawing-frontend).
- Backend: [`../endless-drawing-backend`](../endless-drawing-backend).
- Wire: [JSON v1](../endless-drawing-backend/docs/protocol.md), [MessagePack v2](../endless-drawing-backend/docs/protocol-v2-msgpack.md).
- Визуальный контракт: [brushes.md](../endless-drawing-frontend/docs/brushes.md).

Документы соседних репозиториев — источники совместимости, не файлы этого приложения. Native не меняет протокол/геометрию самостоятельно и пока не предлагает v3.
