# Endless Drawing — iPad

Нативный клиент общего бесконечного холста для iPad и Apple Pencil Pro.

## Принятая основа

- SwiftUI для интерфейса, UIKit для ввода и интеграции с Pencil.
- Metal / MetalKit для аппаратного рендера и плавного взаимодействия.
- Тот же общий мир и WebSocket JSON v1, что у веб-клиента.
- Keychain для секрета владельца; без регистрации и отдельного аккаунта.
- Только холст при запуске; палитра по запросу, без постоянных панелей.

## Документация

1. [План разработки](docs/implementation-plan.md) — решения, этапы, зависимости и критерии готовности.
2. [Подробная архитектура](docs/architecture.md) — модель данных, Metal, Pencil, сеть и хранение.
3. [План проверок](docs/validation.md) — автоматические тесты, совместимость с сайтом и приёмка на iPad.

**Статус:** первый локальный срез M1. В Debug и Release работает один и тот же Metal-холст с круглой кистью, Pencil samples/predictions, finger pan/pinch и контекстной палитрой. Это ещё не общий мир: рисунки живут только в памяти и исчезают при завершении процесса. Локальный режим явно обозначен в палитре; эта сборка предназначена для проверки прототипа, не для публичного выпуска.

Основной набор из 23 тестов проверен на Simulator, включая minimum iPadOS 18.6. Дополнительно добавлен регрессионный тест запуска Metal-холста: 24 теста проверяются в Debug и Release. Сборка для устройства проходит без подписи; физическая приёмка ввода Pencil Pro и производительности ещё не завершена. Подробности: [отчёт M1](docs/progress/m1-local-canvas.md).

## Запуск локального прототипа

Открыть `Endless Drawing.xcodeproj`, выбрать схему **Endless Drawing**, конфигурацию **Debug** и iPad. Тесты — **⌘U**. Нужен Xcode 27.1 с Metal Toolchain; при отсутствии компонента: `xcodebuild -downloadComponent MetalToolchain`.

- Pencil рисует; один палец перемещает, два — перемещают и масштабируют.
- Удержание пальцем 500 ms открывает палитру: цвет, width, opacity, undo и сброс вида.
- Альтернативы: secondary click, ⌘K / Shift+F10 и accessibility-действие «Инструменты»; ⌘Z — undo.
- Пальцы намеренно не рисуют. Double-tap, squeeze и hover Pencil Pro будут подключены на M3.
- Нет Keychain, outbox и сети: не использовать этот срез для рисунков, которые нужно сохранить.

Геометрические fixtures обновляются явно: `node tools/generate-round-fixtures.cjs`. Генератор использует соседний frontend и его установленный TypeScript; обычные Xcode-тесты от Node/frontend не зависят.

## Связанные проекты

- Веб-клиент: [`../endless-drawing-frontend`](../endless-drawing-frontend).
- Backend: [`../endless-drawing-backend`](../endless-drawing-backend).
- Wire-контракт: [`protocol.md`](../endless-drawing-backend/docs/protocol.md).
- Продуктовые правила: [`product.md`](../endless-drawing-frontend/docs/product.md).
- Визуальный контракт кистей: [`brushes.md`](../endless-drawing-frontend/docs/brushes.md).

Документы соседних репозиториев — источники совместимости, а не файлы этого приложения. Изменения протокола и геометрии согласуются между проектами; нативный клиент не вводит их самостоятельно.
