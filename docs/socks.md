# Локальный SOCKS5/HTTP прокси + менюбар-агент (без Network Extension)

Вариант без системного VPN-расширения. Программа `vk-turn-socks` поднимает
**тот же туннель тем же движком** (VK creds, TURN, DTLS/SRTP/WRAP/WRAP-A,
встроенный WireGuard), но терминирует WireGuard в **userspace** (gVisor
netstack) и выставляет наружу локальный **SOCKS5** (TCP + UDP) и опционально
**HTTP** прокси. Вы указываете этот прокси в Surge.

Плюсы: не нужен платный Apple Developer аккаунт, Network Extension, системное
расширение, подпись/нотаризация, cgo. Это обычный исполняемый файл.

Здесь основное:

1. **UDP** — реализован SOCKS5 UDP ASSOCIATE (QUIC/DNS-over-UDP и т.п. идут через туннель).
2. **Три способа запуска** (терминал / фоновый launchd-сервис / менюбар-агент со статистикой) и **авто-failover с Surge** — вынесены в [docs/automation.md](automation.md).
3. **Ручное решение капчи** — в норме движок решает капчу сам; если не смог — менюбар-агент откроет WebView, где вы решаете вручную (либо CLI-режим `-captcha-stdin`, либо вход по cookie).
4. **Гарантия прямого выхода** — трафик самого сервиса всегда идёт напрямую в интернет (к VK TURN), не замыкаясь сам на себя (см. раздел ниже).

## Скачать готовый бинарник (CLI)

Собранные бинарники — в [`dist/`](../dist):

- Apple Silicon (M1–M4): `dist/vk-turn-socks-darwin-arm64`
- Intel: `dist/vk-turn-socks-darwin-amd64`
- Суммы: `dist/SHA256SUMS.txt`

Не подписаны Developer ID, поэтому снимите карантин один раз:

```shell
xattr -dr com.apple.quarantine ./vk-turn-socks-darwin-arm64
chmod +x ./vk-turn-socks-darwin-arm64
```

Либо соберите сами (нужен только Go): `make socks` (или `GOOS=darwin GOARCH=arm64
CGO_ENABLED=0 go build ./cmd/vk-turn-socks`).

## Настройка

Подробная пошаговая инструкция «что откуда брать» (включая **где взять
`private_key`**) — в [docs/config.md](config.md). Если у вас уже настроено
iOS-приложение, самый быстрый путь — импорт готовой ссылки:

```shell
# из iOS connection-link (vkturnproxy://…) или из Full-Backup .json:
./vk-turn-socks-darwin-arm64 -import 'vkturnproxy://import?data=…'
```

Конфиг всегда лежит в одном месте —
`~/Library/Application Support/VKTurnProxy/config.json`. Заполнить вручную:

```shell
mkdir -p ~/Library/Application\ Support/VKTurnProxy
cp cmd/vk-turn-socks/config.example.json ~/Library/Application\ Support/VKTurnProxy/config.json
# отредактируйте файл, затем просто:
./vk-turn-socks-darwin-arm64
```

Ключевые поля (значения — те же, что в приложении): `vk_link`, `peer_addr`
(IP:порт вашего сервера), `mode` (`legacy`|`srtp`|`srtp-wrap`|`srtp-wrap-a`),
`wireguard.private_key`/`peer_public_key` (base64), `wireguard.address`/`dns`,
`socks_listen` (по умолчанию `127.0.0.1:1080`). Для `srtp-wrap` — `wrap_key_hex`,
для `srtp-wrap-a` — `wrap_a_password` (блок `wireguard` не нужен). Опционально
`cookie_header` — залогиненная VK-сессия (тогда только cookie-путь, без анонимного
фолбэка).

   В логе появится `SOCKS5 proxy (TCP + UDP) listening on 127.0.0.1:1080` и строка
`tunnel up via TURN relay <IP> — keep it DIRECT in Surge …` — запомните этот IP
для правила в Surge (см. ниже).

   По умолчанию лог тихий: высокочастотная диагностика движка (memstats,
   HEARTBEAT, pion refresh, поштучная статистика соединений) — родом из
   iOS-расширения и на десктопе не нужна, поэтому она скрыта. Остаются только
   значимые строки (bootstrap, поднятие соединений, периодическая сводка
   `stats:`, предупреждения и ошибки). Флаг `-v` показывает вообще всё
   (для глубокой отладки).

## 1. UDP

SOCKS5 UDP ASSOCIATE поддержан: клиент (Surge) делает UDP-associate по TCP,
шлёт UDP-датаграммы на выданный локальный порт, а `vk-turn-socks` разворачивает
их и отправляет через туннель (netstack UDP), возвращая ответы обратно.
Работает для QUIC/HTTP3 и DNS-over-UDP. Фрагментированные датаграммы
(`FRAG != 0`) не поддерживаются (как и у большинства реализаций) — это нормально.

В Surge включите проксирование UDP для этого прокси (SOCKS5 с UDP relay).

## 2. Менюбар-агент

Приложение в строке меню, которое запускает `vk-turn-socks` как подпроцесс и
общается с ним по локальному control API. Иконка отражает состояние; в меню —
статус, TX/RX, IP TURN-релея, Start/Stop, «Solve captcha…», «Edit config…»,
Quit. Это обычная утилита (`LSUIElement`, без иконки в Dock), **не** системное
расширение — аккаунт Apple не нужен.

Сборка (на Mac; нужен Go + Xcode CLT + xcodegen):

```shell
scripts/build_menubar.sh            # ad-hoc подпись, для локального запуска
# или: TEAM_ID=ВАШ_TEAM scripts/build_menubar.sh   # подпись Developer ID
open "build/DerivedData/Build/Products/Release/VK Turn Proxy Agent.app"
```

Скрипт собирает **универсальный** (arm64+x86_64) `vk-turn-socks`, кладёт его в
Resources агента и собирает `.app`. Конфиг агент хранит в
`~/Library/Application Support/VKTurnProxy/config.json` — при первом запуске
нажмите в меню «Edit config…», заполните и «Start».

> Собранный локально `.app` не имеет карантина, поэтому Gatekeeper его не
> блокирует. Для раздачи на другие Mac подпишите Developer ID и нотаризуйте
> (вложенный бинарник `vk-turn-socks` тоже нужно подписать).

## 3. Ручное решение капчи

По умолчанию движок решает капчу VK автоматически (PoW + slider). Если не
получилось:

- **Менюбар-агент**: в меню появится «Solve captcha…». Откроется окно с WebView,
  где вы проходите «я не робот»; агент перехватывает `success_token` и отдаёт
  его движку через control API — соединение продолжается. (Токен нельзя
  «подсмотреть» в обычном браузере, поэтому нужен встроенный WebView — как в
  полном приложении.)
- **CLI**: запустите с флагом `-captcha-stdin`. Когда потребуется капча, в
  терминал выведется URL; решите его в браузере, а из DevTools → Network →
  ответ `captchaNotRobot.check` скопируйте `success_token` и вставьте в
  терминал.
- **Cookie (самый надёжный фолбэк)**: один раз залогиньтесь в VK в браузере,
  возьмите заголовок `Cookie` (`remixsid=…; p=…`) и положите в `cookie_header`
  — тогда капча вообще не нужна.

Control API (loopback), которым пользуется агент:
`GET /status`, `POST /solve?token=…`, `POST /refresh_captcha`, `POST /stop`
(с заголовком `Authorization: Bearer <token>`, если задан `control_token`).

## 4. Гарантия прямого выхода (нет замыкания на себя)

Трафик **самого сервиса** всегда идёт напрямую в интернет:

- `vk-turn-socks` — это userspace-прокси, он **не меняет системную
  маршрутизацию**. Его собственные исходящие сокеты (к VK API за credentials и к
  VK TURN-релею для WireGuard-транспорта) открываются обычным `net.Dial` по
  дефолтному маршруту ОС — напрямую, минуя и прокси, и туннель.
- Туннель существует только в userspace (netstack): в него попадает **только**
  то, что пришло на локальный SOCKS/HTTP-порт. Зашифрованные WireGuard-пакеты
  выходят наружу через прямые сокеты движка к TURN-релею. То есть вход
  (трафик приложений) и выход (к VK TURN) физически разделены, и выход — прямой.
- Дополнительная защита в коде: туннельный дайлер **отклоняет** цели на loopback
  / unspecified / link-local и на собственные адреса слушателей
  (`dial.go`). Так что даже при кривой конфигурации клиента трафик не может
  завернуться сам на себя.

Единственный способ всё-таки создать петлю — если поверх работает **Surge в
enhanced-mode (системный TUN)** и он перехватывает в том числе сокеты
`vk-turn-socks` к TURN-релею, заворачивая их обратно в прокси `VKTurn`. Чтобы
этого гарантированно не было, добавьте в Surge правила «напрямую» для процесса и
для IP релея (IP печатается в логе при старте):

```ini
[Proxy]
VKTurn = socks5, 127.0.0.1, 1080, udp-relay=true

[Rule]
# процесс самого сервиса — всегда напрямую
PROCESS-NAME,vk-turn-socks,DIRECT
# IP TURN-релея (подставьте тот, что напечатал vk-turn-socks) — напрямую
IP-CIDR,СЮДА_IP_РЕЛЕЯ/32,DIRECT
# локалхост — напрямую
IP-CIDR,127.0.0.1/32,DIRECT
FINAL,VKTurn
```

С этими правилами трафик сервиса всегда уходит напрямую к VK TURN, а через
`VKTurn` идёт только полезный трафик приложений.

## Подключение из Surge

```ini
[Proxy]
VKTurn = socks5, 127.0.0.1, 1080, udp-relay=true
```

Либо через UI: Proxy → SOCKS5 → Host `127.0.0.1`, Port `1080`, включить UDP relay.
HTTP-прокси — включите `http_listen` и укажите `http, 127.0.0.1, 1087`.
