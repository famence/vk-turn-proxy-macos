# Локальный SOCKS5/HTTP прокси (без Network Extension)

Вариант без системного VPN-расширения: маленькая программа `vk-turn-socks`
поднимает **тот же туннель тем же движком** (VK creds, TURN, DTLS/SRTP/WRAP/WRAP-A,
встроенный WireGuard), но не отдаёт пакеты в системный TUN-интерфейс, а
терминирует WireGuard в **userspace** (gVisor netstack) и выставляет наружу
локальный **SOCKS5** и (опционально) **HTTP** прокси. Вы просто указываете этот
прокси в Surge.

Плюсы этого варианта:

- **Не нужен** платный Apple Developer аккаунт, Network Extension, системное
  расширение, подпись и нотаризация.
- Это обычный исполняемый файл — скачал, запустил, готово.
- DNS ходит **через туннель** (без утечек): резолвинг делает netstack по DNS,
  указанному в конфиге.

Ограничения:

- Только **TCP** (SOCKS5 CONNECT + HTTP). UDP ASSOCIATE пока нет — для обычного
  веба это ок; UDP/QUIC пусть Surge гоняет мимо этого прокси (или отключите QUIC).
- Нет WebView для капчи. Движок в большинстве случаев решает капчу VK
  автоматически (PoW + slider). Если VK принудительно требует нерешаемую капчу,
  bootstrap не завершится — повторите попытку или используйте вход по cookie
  (`cookie_header`).

## Скачать готовый бинарник

Собранные бинарники лежат в [`dist/`](../dist):

- Apple Silicon (M1/M2/M3/M4): `dist/vk-turn-socks-darwin-arm64`
- Intel: `dist/vk-turn-socks-darwin-amd64`

Контрольные суммы — `dist/SHA256SUMS.txt`.

> Бинарники не подписаны Developer ID, поэтому Gatekeeper при первом запуске их
> заблокирует. Это нормально для CLI-утилиты — снимите карантин один раз:
> ```shell
> xattr -dr com.apple.quarantine ./vk-turn-socks-darwin-arm64
> chmod +x ./vk-turn-socks-darwin-arm64
> ```

Либо соберите сами (нужен только Go, без Xcode):

```shell
GOOS=darwin GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" \
  -o vk-turn-socks ./cmd/vk-turn-socks
```

## Настройка

1. Скопируйте пример конфига и заполните его:

   ```shell
   cp cmd/vk-turn-socks/config.example.json config.json
   ```

   Ключевые поля (значения — те же, что в приложении):

   - `vk_link` — ссылка на VK-звонок;
   - `peer_addr` — `IP:порт` вашего сервера vk-turn-proxy (то, что в `-listen`);
   - `mode` — `legacy` | `srtp` | `srtp-wrap` | `srtp-wrap-a`;
   - `wireguard.private_key` / `peer_public_key` — base64-ключи (как в `wg genkey`);
   - `wireguard.address` / `dns` — адрес клиента в туннеле и DNS через туннель;
   - `socks_listen` — где слушать SOCKS5 (по умолчанию `127.0.0.1:1080`);
   - для `srtp-wrap` заполните `wrap_key_hex`; для `srtp-wrap-a` — `wrap_a_password`
     (блок `wireguard` не нужен, сервер выдаёт конфиг через GETCONF);
   - опционально `cookie_header` — залогиненная VK-сессия (`remixsid=…; p=…`),
     тогда движок работает только по cookie-пути (без анонимного фолбэка).

2. Запустите:

   ```shell
   ./vk-turn-socks-darwin-arm64 -config config.json
   # или переопределить порт: -socks 127.0.0.1:1080  (и -http 127.0.0.1:1087)
   ```

   В логе появится `SOCKS5 proxy listening on 127.0.0.1:1080` и раз в 30 секунд —
   строка статистики (uptime, соединения, пул credential'ов, TX/RX).

## Подключение из Surge

Добавьте прокси в Surge (`[Proxy]`):

```ini
[Proxy]
VKTurn = socks5, 127.0.0.1, 1080
```

Или через UI: Proxy → добавить SOCKS5 → Host `127.0.0.1`, Port `1080`.
Затем направьте нужные правила на прокси `VKTurn` (или через свою `[Proxy Group]`).

Если предпочитаете HTTP-прокси — включите `http_listen` в конфиге и укажите в
Surge `http, 127.0.0.1, 1087`.

> Рекомендация: в Surge включите проксирование DNS через прокси (или используйте
> DoH внутри Surge). Сам `vk-turn-socks` резолвит имена через туннель, поэтому
> при передаче Surge доменных имён (SOCKS5 с hostname) утечки DNS не будет.

## Автозапуск (по желанию)

Чтобы прокси стартовал в фоне при входе — оберните в `launchd`-агент
(`~/Library/LaunchAgents/…plist`) с путём к бинарнику и `-config`. Это обычная
пользовательская утилита, root не нужен.
