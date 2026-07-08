# VK TURN Proxy — macOS

Порт [vk-turn-proxy-ios](https://github.com/anton48/vk-turn-proxy-ios) на macOS.
Строит туннель к вашему серверу поверх [TURN relay](https://www.rfc-editor.org/info/rfc8656/)
ВКонтакте — работает даже там, где фильтруется трафик. Движок (Go: VK-креды,
TURN, DTLS/SRTP/WRAP/WRAP-A, встроенный WireGuard, авто-капча) — тот же, что в
iOS-версии.

Два варианта на выбор:

| | Приложение (.app) | Прокси для Surge |
|---|---|---|
| Что делает | Системный VPN на весь Mac | Локальный SOCKS5/HTTP, подключаете Surge |
| Нужен Apple Developer аккаунт | Да (платный) | Нет |
| Установка | Сборка в Xcode | Скачать `.dmg`, перетащить в Applications |

Для большинства проще **прокси для Surge** — он ставится в пару кликов и не
требует аккаунта Apple.

## Установка (прокси для Surge)

1. Скачайте `VK-Turn-Proxy-Agent.dmg` из [Releases](../../releases)
   (универсальный — Apple Silicon и Intel).
2. Откройте, перетащите **VK Turn Proxy Agent** в **Applications**, запустите.
3. Первый запуск: правый клик по приложению → **Open** (сборка без подписи).
4. В иконке в трее → **Edit config…**, заполните настройки
   ([docs/config.md](docs/config.md)).

Только CLI без интерфейса — тоже в Releases (`vk-turn-socks-darwin-arm64.zip` /
`-amd64.zip`).

## Автоматический режим (без участия)

В панели трея включите **Auto (failover)** и **Launch at login**. Дальше всё
само: агент стартует при входе в систему, поднимает туннель только когда прямой
интернет недоступен, и гасит его, когда доступ возвращается.

В Surge добавьте `fallback`-группу, чтобы маршрут переключался автоматически:

```ini
[Proxy]
VKTurn = socks5, 127.0.0.1, 1080, udp-relay=true

[Proxy Group]
Auto = fallback, DIRECT, VKTurn, url=http://www.gstatic.com/generate_204, interval=30, timeout=3

[Rule]
DOMAIN,www.gstatic.com,DIRECT
PROCESS-NAME,vk-turn-socks,DIRECT
IP-CIDR,127.0.0.1/32,DIRECT
FINAL,Auto
```

Подробнее — [docs/automation.md](docs/automation.md).

## Документация

- [Настройка конфига (где взять ключи)](docs/config.md)
- [Установка, запуск, авто-режим, Surge](docs/automation.md)
- [CLI-запуск и Surge](docs/socks.md)
- [Полное приложение (.app) с системным VPN](docs/setup.md)

## Сборка из исходников

Нужны macOS 13+, Xcode 16.2+, Go 1.25.5+, `xcodegen` (`brew install go xcodegen`).

```shell
make socks       # headless CLI-бинарь
scripts/build_menubar.sh    # менюбар-приложение (.app)
scripts/package_dmg.sh      # .dmg + CLI-зипы (как в релизе)
```

Релизы собираются автоматически (GitHub Actions) при пуше тега `vX.Y.Z`.

## License

[GPL-3.0](LICENSE), как производная от
[vk-turn-proxy](https://github.com/cacggghp/vk-turn-proxy).
