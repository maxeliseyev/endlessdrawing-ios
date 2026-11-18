# M2.2 — нативный MessagePack v2 и WebSocket transport

Следующий срез уже реализован: [M2.3 — подключение общего Canvas](m2-shared-canvas.md). Ниже историческое состояние M2.2; его ограничения не являются текущим статусом приложения.

## Статус и границы

Реализован нативный T1 codec/transport поверх M2.1. Это соответствует бинарному M1 frontend/backend, **не** manifest/visible-first и **не** завершённому подключению Canvas к общему миру.

В приложении пока остаётся локальный холст. `WorldSession`, SceneStore, mutation scheduler и renderer всех четырёх форм ещё нужны до включения shared-world UI. Никакие production-сокеты не открывались автоматически, реальные рисунки в общий мир тестами не отправлялись.

Нормативный источник теперь [backend protocol-v2-msgpack.md](../../../endless-drawing-backend/docs/protocol-v2-msgpack.md), а не прежний frontend draft. В соседних репозиториях уже реализованы v2 и последующий v3/manifest; их production rollout этим native-прогоном не проверялся. Нативный клиент в рамках этого среза намеренно предлагает только согласованные v2/v1, без manifest.

## Реализация

### Codec и guards

- `Networking/SessionCodec.swift`: immutable `TransportProfile` и `SessionCodec`, явная `TransportPolicy.negotiated` либо заранее выбранная `.legacyJSONV1`.
- Offers: `endless-drawing.msgpack.v2`, затем `endless-drawing.json.v1`. Nil/empty/unknown/v3 при negotiated mode отвергаются; auto-legacy retry нет.
- V2 — Binary MessagePack с ack version 2; explicit/legacy v1 — Text JSON с ack version 1. Message type не угадывается по payload.
- `WireProtocol.swift`: прежние application guards переиспользуются через Codable. Decoder context проверяет hello version относительно codec; binary chunk дополнительно ограничен 8192 points. JSON v1 сохраняет прежние limits.
- Server receive: 256 KiB v2 / 4 MiB legacy/explicit JSON; client body ≤128 KiB, включая фактическое окончательное encoding. Negotiated socket начинает с ceiling 256 KiB ещё до selection; после выбора JSON повышается до 4 MiB до hello. SDK POSIX EMSGSIZE и URL dataLengthExceedsMaximum классифицируются как oversize, не generic network.
- `MessagePackPreflight.swift`: перед библиотекой проверяет single top-level map, exact consumption, длины/доступные bytes до allocations, depth 8, nodes 65536, arrays 2000, maps 16, UTF-8 strings 256 bytes; duplicate/non-string/опасные keys, bin/ext/nil/float32, non-finite и unsafe integers отвергаются.
- Numeric geometry может быть integer или float64; seq/protocol_version остаются integer. UUID — строки. Нет JSON-промежуточного представления, Base64-оболочки или сжатия application messages.
- Ошибки кодека не содержат raw payload/diagnostics; requested Close codes: 1003 wrong type, 1009 oversize, 1007 malformed/budget, 1002 incompatible profile/version.

### Зависимость и точность

SPM: [`fumoboy007/msgpack-swift`](https://github.com/fumoboy007/msgpack-swift), exact **2.0.6**, revision `fe3101819f4f82b086da5279a9df81f6754798e9`, product `DMMessagePack`, module `MessagePack`. `Package.resolved` зафиксирован. Runtime target без внешних зависимостей, minimum iOS 16, наш deployment target 18.6 не менялся. MIT notice включён в app resources как `MessagePack-LICENSE.txt`.

При аудите альтернативы Flight-School/MessagePack 1.2.4 обнаружены crash paths в nested keyed containers и ограничения integer→Double; она не подключалась к проекту.

Выбранная библиотека корректно поддерживает Codable, integer→Double без потерь и integer-only decoding для seq. Но её encoder автоматически сокращает **точно представимые** Double до float32, что запрещено нашим wire profile. Поэтому bounded адаптер **только trusted encoder output** разворачивает такие значения обратно в float64, не меняя containers/keys/прочие значения. Это не новый MessagePack encoder и не разрешение float32 на приём.

Проверены исходные Double bit patterns, включая -0, дроби у ±1e9 и минимальное subnormal. После расширения снова учитывается реальный byte limit. Самописного encoder, модифицированного upstream package или lossy conversion нет; входящий float32 остаётся ошибкой.

### Standalone URLSession transport

`Networking/WebSocketTransport.swift`:

- Один active socket, immutable selected codec на connection generation, одна последовательная receive loop и один serial send path.
- Delegate проверяет selected protocol до возврата Connection; только затем caller может послать hello. Transport сам не генерирует owner и не заменяет application handshake FSM.
- Explicit Origin в отдельной ephemeral URLSession, cookies/cache выключены. Legacy mode создаёт task из URLRequest без offers; negotiated mode использует SDK API URL+protocols.
- TLS остаётся системным, trust-all delegate нет; HTTP redirects не разрешены.
- Incoming buffer ≤16 messages, каждое ограничено profile byte/node/domain limits. Overflow завершает stream явно, не теряет события молча. Будущий WorldSession должен resnapshot после ошибки.
- Outgoing ≤32 messages / 512 KiB, включая активный send. Ping идёт через тот же writer. Connect deadline 8 s, send/pong deadline 12 s.
- Disconnect/cancellation/старые delegate callbacks проверяют generation и не закрывают новый socket. Continuations разрешаются при закрытии; ресурсы освобождаются также при deinit.
- Close frame запрашивается до `finishTasksAndInvalidate`, а не немедленного abort всей session.

Transport не реализует automatic reconnect/backoff, hello/snapshot/ack deadlines уровня WorldSession, 5/20/5 mutation limits или authoritative scene. Cancellation после возможного начала send считается unknown result: journal нельзя очищать из-за transport error.

## Общие fixtures и межъязыковая проверка

Неизменяемая test-only копия backend corpus: `Endless DrawingTests/Fixtures/ws-v2/`, 25 semantic messages, по файлу от каждого из двух исходных энкодеров. SHA256 manifest проверяется в native suite. Provenance: `ws-v2-source.json`.

- На финальной проверке spec и fixture manifest совпадают с committed backend `3bdb9887e7e2c8bf93e3542610f6c1a739a7a19b`; provenance помечен `matchesCommittedSource`. Первоначальный planning baseline `4103b38` больше не описывает состояние этих source files.
- Manifest SHA256: `3c1cff312ce0390b7f2f454d3ccb974f5f909395c8c54ab7d99d9a2b56df9a69`.
- Normative spec SHA256 при чтении: `19f9560d992f7fd350d6dd98b37271192c2661f8a544cd4934863524b4a01fd8`.
- Native читает обе версии каждого сообщения и сравнивает semantic values с corpus, не требует каноничного порядка map/ширины integer.
- Native тест пишет **actual-output artifacts** в Simulator tmp, не перегенерирует pinned expected fixtures. `tools/verify-native-msgpack.cjs` читает их настоящим bounded frontend codec. Все 25 Swift messages прошли проверку, 3132 application bytes; bodies не логируются. Frontend на финальной проверке: `4948f2162de86aed451468a78d600466b204b6da`.

Важное ограничение корпуса: некоторые synthetic strokes идут от ~1e9 к -1, то есть превышают create extent limit 100000, и snapshot повторяет UUID для разных brush. Это fixtures транспортной семантики, не разрешение ослабить domain/scene invariants. Pure codec их читает; typed application parsing сохраняет extent rejection. Отдельные valid native DTO tests проверяют все необходимые типы и geometry, а 2000-point case имеет допустимые bounds.

Swift output проверен frontend decoder. Запуск именно backend decoder на Swift artifacts и настоящая native→backend/Postgres интеграция в этом срезе не выполнялись; loopback peer ниже не выдаётся за реальный backend.

## Выполненные проверки

Прогон 2026-11-18, Xcode 27.1, native рабочее дерево поверх `f769baf` (не новый commit).

| Прогон | Результат |
| --- | --- |
| Debug, iPad M4 Simulator / iPadOS 18.6, ad-hoc signed | 81 PASS, 11 suites |
| Debug, iPad M4 Simulator / runtime iOS 27.0, ad-hoc signed | 81 PASS |
| Release, тот же runtime 27.0, ad-hoc signed, testability | 81 PASS |
| Release generic iOS device, без подписи | BUILD SUCCEEDED |
| Swift → actual frontend bounded decoder | 25/25 semantic corpus PASS |
| App/test strict concurrency, warnings as errors | PASS |

Новые проверки: protocol selection, Text/Binary/version mismatch, обе fixture-копии и hashes, float64 output adapter/expanded cap, malformed/truncated/unsafe/huge headers/depth/node budgets, 2000 points, binary chunk point cap без регрессии JSON, profile-independent journal retry.

Настоящие loopback WebSocket Upgrade идут через Network.framework peer и URLSession, не FakeSocket. Проверены Origin, ordered messages, v2 / JSON rollback / explicit legacy, Ping/Pong, отказ при отсутствии selected profile без второго handshake, wrong version/frame type, реальное превышение SDK message ceiling, receive backpressure и replacement после cancellation. Peer — только test control messages и empty snapshots, не DB/ownership implementation.

Для фиксированного synthetic 2000-point trajectory: JSON **78131 bytes**, MessagePack **38167 bytes**, примерно **49%** JSON application payload. Это не TLS/TCP/WS traffic, CPU benchmark или утверждение о любых рисунках. FPS/latency/GPU time этим не измерялись. Общая цель ≤60% выполнена на этом корпусе.

## Воспроизведение

Подпись Simulator нужна для настоящего Keychain из M2.1:

```bash
IPAD_SIMULATOR_ID='<UUID>'
xcodebuild -project 'Endless Drawing.xcodeproj' \
  -scheme 'Endless Drawing' -configuration Debug \
  -destination "platform=iOS Simulator,id=$IPAD_SIMULATOR_ID" \
  -derivedDataPath /tmp/endless-drawing-signed-tests \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- \
  -collect-test-diagnostics never test

APP_DATA=$(xcrun simctl get_app_container "$IPAD_SIMULATOR_ID" maximeliseyev.endlessdrawing data)
node tools/verify-native-msgpack.cjs "$APP_DATA/tmp/ws-v2-swift-interop"
```

Для Release добавить `ENABLE_TESTABILITY=YES`. Warnings-as-errors теперь заданы в собственном Xcode project для app/tests. **Не передавать `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` глобальным CLI override:** Xcode добавляет зависимостям `-suppress-warnings`, что конфликтует с глобальным `-warnings-as-errors`. Собственный код проверяется строго, dependency policy отдельно.

Ordinary tests не изменяют общий corpus и не требуют Node/frontend; Node нужен только отдельному cross-language verifier. SPM нужен для первой загрузки pinned зависимости.

## Следующий срез

1. Native ↔ настоящий dev backend smoke, включая server `WS_MSGPACK_ENABLED=false`, mixed JSON/binary clients, create/delete/idempotency и reconnect.
2. WorldSession + progressive SceneStore + journal integration и mutation rate scheduling.
3. Square/chisel/spray renderer перед открытием произвольной общей области; включение shared-world Canvas только после этого gate.
4. Device/HTTPS/WAN acceptance. Production activation — после проверки deployed server negotiation, не auto-legacy downgrade.
5. Native adoption существующего v3/manifest и последующий visible-first — отдельная задача, не часть этого T1. Не предлагать v3 до реализации его native FSM и fixture gates.
