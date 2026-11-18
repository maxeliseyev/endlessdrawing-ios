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

**Статус:** проектирование. В `Endless Drawing/` пока исходный SwiftUI/SwiftData-шаблон, не реализация описанной архитектуры. iPad-only и deployment target iPadOS 18.6 уже заданы в Xcode-проекте. Наличие SDK с Pencil API не заменяет проверку на устройстве.

## Связанные проекты

- Веб-клиент: [`../endless-drawing-frontend`](../endless-drawing-frontend).
- Backend: [`../endless-drawing-backend`](../endless-drawing-backend).
- Wire-контракт: [`protocol.md`](../endless-drawing-backend/docs/protocol.md).
- Продуктовые правила: [`product.md`](../endless-drawing-frontend/docs/product.md).
- Визуальный контракт кистей: [`brushes.md`](../endless-drawing-frontend/docs/brushes.md).

Документы соседних репозиториев — источники совместимости, а не файлы этого приложения. Изменения протокола и геометрии согласуются между проектами; нативный клиент не вводит их самостоятельно.
