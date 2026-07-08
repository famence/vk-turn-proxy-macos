# Установка, запуск и авто-режим

## Установка приложения

1. Скачайте `VK-Turn-Proxy-Agent.dmg` из [Releases](../../releases)
   (универсальный: Apple Silicon + Intel).
2. Откройте DMG, перетащите **VK Turn Proxy Agent** в **Applications**, запустите.
3. Первый запуск (сборка без подписи): правый клик → **Open** → **Open**. Либо:
   `xattr -dr com.apple.quarantine "/Applications/VK Turn Proxy Agent.app"`.
4. В трее → **Edit config…**, заполните настройки ([config.md](config.md)).

## Где лежит конфиг

Один файл: `~/Library/Application Support/VKTurnProxy/config.json`. Его
используют приложение, сервис и CLI. Открыть/показать — кнопки **Edit config…**
и **Reveal** в трее. Импорт из iOS:

```shell
vk-turn-socks -import 'vkturnproxy://import?data=…'
```

## Автоматический режим (рекомендуется)

В трее включите:

- **Launch at login** — агент стартует при входе в систему.
- **Auto (failover)** — туннель поднимается только когда прямой интернет
  недоступен, и останавливается, когда доступ возвращается.

Плюс `fallback`-группа в Surge переключает маршрут DIRECT ⇆ туннель
автоматически. Полный конфиг Surge:

```ini
[Proxy]
VKTurn = socks5, 127.0.0.1, 1080, udp-relay=true

[Proxy Group]
Auto = fallback, DIRECT, VKTurn, url=http://www.gstatic.com/generate_204, interval=30, timeout=3

[Rule]
# проба связности — всегда напрямую (в обход туннеля)
DOMAIN,www.gstatic.com,DIRECT
# трафик самого сервиса — напрямую (без петли)
PROCESS-NAME,vk-turn-socks,DIRECT
IP-CIDR,127.0.0.1/32,DIRECT
FINAL,Auto
```

Результат: подключение и отключение происходят сами, участие не требуется.

## Другие способы запуска

**Терминал:**

```shell
vk-turn-socks          # берёт конфиг из app-support
```

**Фоновый сервис (launchd), без приложения:**

```shell
scripts/service.sh install     # поставить и запустить (автозапуск при входе)
scripts/service.sh start|stop|status|logs|uninstall
```

## Решение капчи

Обычно решается автоматически. Если нет — в трее появится кнопка
**Solve captcha…** (откроется окно, пройдите проверку). Альтернатива — вход по
`cookie_header` в конфиге (капча тогда не нужна).
