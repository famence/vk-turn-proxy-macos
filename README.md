# VK TURN Proxy — macOS

Порт [vk-turn-proxy-ios](https://github.com/anton48/vk-turn-proxy-ios) на macOS.
То же самое приложение, тот же движок «под капотом», те же режимы работы — но
нативное для Mac.

Приложение разработано в исследовательских и образовательных целях. Оно строит
туннель (VPN) между устройством и вашим сервером. Туннель поднимается поверх
[TURN relay](https://www.rfc-editor.org/info/rfc8656/) (по умолчанию — relay
[ВКонтакте](https://vk.com), либо любой другой TURN relay из настроек).
Использование TURN relay как промежуточного звена позволяет работать в том числе
в условиях фильтрации трафика в корпоративной сети или у сотового провайдера.

## Что взято от iOS-версии без изменений

«Под капотом» — ровно тот же код, что и в iOS-приложении:

- **Ядро на Go** (`pkg/proxy`, `pkg/turnbind`, `WireGuardBridge`) — получение VK
  credentials, аллокации TURN, DTLS/SRTP/WRAP/WRAP-A транспорты, встроенный
  WireGuard, пул credential'ов, авто-решение капчи (PoW + slider), watchdog,
  smart-pause на смену сети. Скомпилировано в `WireGuardTURN.xcframework`.
- **Вся бизнес-логика на Swift** — `TunnelManager`, `BackupManager`,
  `ConfigValidation`, `CredCache`, `VKProfileCache`, `VKCookieStore`,
  модели конфигурации, парсинг connection-link / `wdtt://`, экспорт/импорт бэкапов.
- **Тот же протокол между Swift и Go** — те же C-функции
  (`wgStartVKBootstrap`, `wgWaitBootstrapReady`, `wgAttachWireGuard`,
  `wgProbeVKCreds`, …) и та же последовательность запуска туннеля.

## Что отличается от iOS (и почему)

macOS — не iOS, поэтому изменилась только «обёртка» вокруг ядра:

| iOS | macOS | Почему |
|-----|-------|--------|
| Packet Tunnel как **app extension** | Packet Tunnel как **system extension** | На macOS packet-tunnel-провайдер при распространении вне Mac App Store должен быть системным расширением (Apple TN3134). Требует однократного подтверждения пользователем. |
| UIKit-обёртки (`UIActivityViewController`, `UIDocumentPicker`, `UITextView`, `UIPasteboard`) | AppKit (`NSSavePanel`, `NSOpenPanel`, `NSTextView`, `NSPasteboard`) | UIKit на Mac недоступен; логика та же, элементы нативные. |
| `NEHotspotNetwork` для SSID в диагностике | `CoreWLAN` | На Mac имя Wi-Fi-сети читается через CoreWLAN. |
| App Group `group.com.vkturnproxy.app` | App Group `<TeamID>.com.vkturnproxy.mac` | macOS-контейнеры App Group должны быть с префиксом Team ID. |
| Лимит памяти Go 35 МБ (jetsam iOS) | 512 МБ | На Mac нет per-process jetsam-потолка для расширения; поднятый лимит возвращает полноскоростную работу GC. |

Всё остальное (UI, экраны, настройки, режимы, бэкапы, авто-ссылки) — 1:1 с iOS.

## Сборка

Нужен Mac с Xcode 16.2+, Go 1.25.5+ и [`xcodegen`](https://github.com/yonaskolb/XcodeGen)
(`brew install go xcodegen`).

```shell
# 1) собрать Go-ядро в WireGuardBridge/build/WireGuardTURN.xcframework
make bridge

# 2) сгенерировать Xcode-проект из project.yml
make project

# 3) открыть проект, задать свой Team ID и собрать/запустить
open VKTurnProxy/VKTurnProxy.xcodeproj
```

Или всё сразу: `make all`, затем открыть проект в Xcode.

Подробности (Team ID, entitlements, подтверждение системного расширения,
notarization) — в [docs/setup.md](docs/setup.md).

## Вариант без Network Extension (SOCKS5/HTTP для Surge)

Если не хочется возиться с системным расширением, платным аккаунтом Apple и
подписью — есть лёгкий вариант: программа `vk-turn-socks` поднимает **тот же
туннель тем же движком**, но терминирует WireGuard в userspace и отдаёт наружу
локальный **SOCKS5/HTTP** прокси. Вы подключаетесь к нему из Surge.

Это обычный исполняемый файл (без Xcode, без Network Extension, без аккаунта
Apple). Готовые бинарники — в [`dist/`](dist) (Apple Silicon и Intel), инструкция
и настройка Surge — в [docs/socks.md](docs/socks.md), а подробная настройка
конфига (в т.ч. **где взять `private_key`**) — в [docs/config.md](docs/config.md).

Если уже настроено iOS-приложение — перенос в одну команду:
`./vk-turn-socks -import 'vkturnproxy://import?data=…' -config config.json`.

```shell
cp cmd/vk-turn-socks/config.example.json config.json   # заполнить своими данными
xattr -dr com.apple.quarantine ./dist/vk-turn-socks-darwin-arm64
./dist/vk-turn-socks-darwin-arm64 -config config.json
# в Surge: Proxy → SOCKS5 → 127.0.0.1:1080 (udp-relay=true)
```

Возможности этого варианта:
- **SOCKS5 TCP + UDP** (UDP ASSOCIATE — работает QUIC/HTTP3, DNS-over-UDP) и HTTP-прокси.
- **Три способа запуска** — терминал, фоновый launchd-сервис ([`scripts/service.sh`](scripts/service.sh)) и **менюбар-агент со статистикой** (`VK Turn Proxy Agent.app`, `scripts/build_menubar.sh`). Подробно — [docs/automation.md](docs/automation.md).
- **Авто-failover с Surge** — DIRECT пока прямой интернет жив, автоматически в туннель когда пропал, обратно на DIRECT когда вернулся (нативная `fallback`-группа Surge + режим Auto в агенте). См. [docs/automation.md](docs/automation.md#авто-failover-с-surge-direct--vk-turn).
- **Ручное решение капчи** — авто по умолчанию; если не вышло, агент откроет WebView для ручного решения (или CLI `-captcha-stdin`, или вход по `cookie_header`).
- **Прямой выход без петель** — сервис всегда ходит к VK TURN напрямую (userspace-прокси не меняет маршрутизацию; дайлер блокирует loopback/self). Для Surge в enhanced-mode добавьте `PROCESS-NAME,vk-turn-socks,DIRECT` + IP релея — подробности в [docs/socks.md](docs/socks.md#4-гарантия-прямого-выхода-нет-замыкания-на-себя).
- **Стандартный путь конфига** — `~/Library/Application Support/VKTurnProxy/config.json` (общий для CLI, сервиса и агента).

## Документация

- [Как это работает / что нужно для работы / режимы](docs/setup.md)
- [Сборка и установка полноценного .app на macOS](docs/setup.md#сборка-и-установка-на-macos)
- [Лёгкий вариант: SOCKS5/HTTP прокси для Surge (без Network Extension)](docs/socks.md)

## Credits

Порт [anton48/vk-turn-proxy-ios](https://github.com/anton48/vk-turn-proxy-ios),
который основан на [vk-turn-proxy](https://github.com/cacggghp/vk-turn-proxy)
by [cacggghp](https://github.com/cacggghp).

## License

[GNU General Public License v3.0](LICENSE) (GPL-3.0) — как производная от
[vk-turn-proxy](https://github.com/cacggghp/vk-turn-proxy) (GPL-3.0).

Файлы с заголовком `SPDX-License-Identifier` дополнительно доступны под указанной
там лицензией (например, MIT); проект в целом — GPL-3.0.
