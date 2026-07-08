# CLI: vk-turn-socks

Headless вариант: поднимает локальный **SOCKS5** (TCP + UDP) и **HTTP** прокси,
через который выходит Surge. Без Network Extension, без аккаунта Apple.

Для большинства удобнее приложение с треем и авто-режимом — см.
[automation.md](automation.md). Ниже — прямой запуск из терминала.

## Запуск

```shell
# конфиг: см. config.md; импорт из iOS одной командой:
vk-turn-socks -import 'vkturnproxy://import?data=…'

# запуск (конфиг берётся из ~/Library/Application Support/VKTurnProxy/config.json):
vk-turn-socks
```

Флаги: `-config <путь>` (override), `-socks 127.0.0.1:1080`, `-http 127.0.0.1:1087`,
`-captcha-stdin` (ручная капча в терминале), `-v` (полный лог).

## Подключение из Surge

```ini
[Proxy]
VKTurn = socks5, 127.0.0.1, 1080, udp-relay=true
```

Автоматическое переключение DIRECT ⇆ туннель и правила «прямого выхода» —
в [automation.md](automation.md).

## Возможности

- SOCKS5 CONNECT (TCP) и UDP ASSOCIATE (QUIC/HTTP3, DNS-over-UDP), HTTP-прокси.
- DNS резолвится через туннель (без утечек).
- Все 4 режима сервера: `legacy`, `srtp`, `srtp-wrap`, `srtp-wrap-a`.
- Трафик сервиса всегда идёт напрямую к VK TURN; дайлер не допускает
  замыкания на loopback/себя.
