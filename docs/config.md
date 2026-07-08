# Настройка конфига

Конфиг описывает клиентскую сторону: какой VK-звонок использовать, адрес вашего
сервера и WireGuard-ключи. Предполагается, что сервер уже настроен: VPS с
запущенным `vk-turn-proxy` (`-listen IP:порт`) и WireGuard-сервером.

Файл всегда один: `~/Library/Application Support/VKTurnProxy/config.json`.
Редактировать удобнее из трея — **Edit config…**.

## Способ A: перенести из iOS (проще всего)

Если пользуетесь iOS-приложением, экспортируйте настройки одной ссылкой и
импортируйте:

```shell
vk-turn-socks -import 'vkturnproxy://import?data=…'      # ссылка vkturnproxy://
vk-turn-socks -import ./vkturnproxy-backup-….json        # или файл Full Backup
```

Ссылку даёт скрипт `quick_link.py`, тот, кто настраивал сервер, или
«Export Full Backup» в iOS-приложении.

## Способ B: с нуля

`private_key` — приватный ключ WireGuard-клиента; его генерируют (не «берут
готовым»). Есть пара: приватный (у клиента) + публичный (на сервере в `[Peer]`).

Сгенерировать пару и получить блок `[Peer]` для сервера:

```shell
python3 quick_link.py -gen-peer-key 192.168.102.7/24
```

Скрипт печатает ссылку `vkturnproxy://…` (импортируйте её, Способ A) и блок
`[Peer]` — добавьте его в конфиг WireGuard-сервера и перезапустите WireGuard.
Заранее заполните в `quick_link.py` поля `peerPublicKey`, `vkLink`, `peerAddress`.

Либо через `wg`: `wg genkey | tee priv.key | wg pubkey > pub.key`.

## Поля

| Поле | Значение |
|---|---|
| `vk_link` | Ссылка на VK-звонок `https://vk.ru/call/join/…` (звонок активен) |
| `peer_addr` | `IP:порт` `-listen` вашего сервера (не порт WireGuard, не TURN-релей) |
| `mode` | `srtp` (по умолч.), `legacy`, `srtp-wrap`, `srtp-wrap-a` — как запущен сервер |
| `use_udp` | `false` (TCP устойчивее); `true` только если сеть режет TCP |
| `num_conns` | `30` — больше скорость, но больше запросов к VK |
| `wireguard.private_key` | Приватный ключ клиента (base64) |
| `wireguard.peer_public_key` | Публичный ключ **сервера** WireGuard (base64) |
| `wireguard.preshared_key` | Только если задан на сервере, иначе `""` |
| `wireguard.address` | IP клиента в туннеле, совпадает с `AllowedIPs` на сервере |
| `wireguard.dns` | DNS через туннель, напр. `1.1.1.1` |
| `wrap_key_hex` | Только для `srtp-wrap` (64 hex, `= -wrap-key` сервера) |
| `wrap_a_password` | Только для `srtp-wrap-a` (блок `wireguard` тогда не нужен) |
| `cookie_header` | Опционально: вход по VK-сессии (`remixsid=…; p=…`), без анонимного пути и капчи |

## Если не работает

- **`srtp handshake … context deadline exceeded`** — не совпал `mode` или
  `peer_addr`: `mode` должен соответствовать флагам сервера (`srtp` ⇒ сервер с
  `-srtp`), `peer_addr` — адрес `-listen` (не WireGuard-порт).
- **Туннель «up», но интернета нет; `rx=0`, реконнекты по кругу** — несовпадение
  WireGuard: `peer_public_key` = публичный ключ **сервера** (в 3x-ui это ключ
  самого inbound'а, а не пира); публичный ключ вашего `private_key` должен быть
  добавлен на сервер как `[Peer]` с нужным `AllowedIPs`. Не запускайте iOS и Mac
  одновременно с одним ключом/адресом.
- **Потерян приватный ключ** — сгенерируйте новый (Способ B) и добавьте новый
  `[Peer]` на сервер.

Надёжнее всего — импортировать рабочие настройки из iOS (Способ A).
