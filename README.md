# Слепок: снимки резервных копий для Linux на rsync

Каждую ночь делает полный снимок нужных папок на внешний диск или NAS, но места тратит только на изменившиеся файлы: всё остальное становится жёсткими ссылками на прошлый снимок. Старые снимки удаляются по понятным правилам («7 дней, 4 недели, 12 месяцев»), а любой файл можно достать в той версии, какой он был в нужный день.

![Bash](https://img.shields.io/badge/Bash_4.4+-4EAA25?style=flat&logo=gnubash&logoColor=white)
![rsync](https://img.shields.io/badge/rsync-0F5C8C?style=flat&logo=linux&logoColor=white)
![systemd](https://img.shields.io/badge/systemd-201A1E?style=flat&logo=linux&logoColor=white)
![ShellCheck](https://img.shields.io/badge/ShellCheck-3E3E3E?style=flat&logo=gnubash&logoColor=white)
![GitHub Actions](https://img.shields.io/badge/GitHub_Actions-2088FF?style=flat&logo=githubactions&logoColor=white)

```text
$ sudo slepok backup
Снимок 2026-10-20_030412, основа: 2026-10-19_030207
  объектов в снимке: 184213, скопировано заново: 37 (212.4 MiB), остальное взято жёсткими ссылками
Готово: /mnt/backup/slepok/2026-10-20_030412
Ротация снимков:
  оставить  2026-09-30_030115  (месяц)
  удалить   2026-10-12_030544
  оставить  2026-10-13_030321  (неделя)
  ...
  оставить  2026-10-20_030412  (последний, день, неделя, месяц)
Удалено снимков: 1, освобождено 96.3 MiB

$ slepok list
SNAPSHOT                 ADDED
2026-09-30_030115     41.7 GiB  полная копия
2026-10-13_030321    388.0 MiB
2026-10-19_030207    120.5 MiB
2026-10-20_030412    212.9 MiB  <- latest

Снимков: 4, занято на диске: 42.4 GiB, без жёстких ссылок было бы: 167.1 GiB

$ slepok history /home/alex/Документы/договор.docx
2026-09-30_030115    48.2 KiB  изменён 2026-09-28 17:40
2026-10-19_030207    51.0 KiB  изменён 2026-10-18 12:03
Версий: 2. Достать нужную: slepok restore СНИМОК /home/alex/Документы/договор.docx КУДА
```

## Возможности

**Снимки**
- Каждый снимок выглядит как полная копия: обычная папка, которую можно открыть файловым менеджером без всякого slepok.
- Неизменившиеся файлы связываются жёсткими ссылками с прошлым снимком (`rsync --link-dest`), поэтому ежедневный снимок 100 ГБ домашней папки занимает столько, сколько за день изменилось.
- Снимок пишется во временную папку `.inprogress-*` и переименовывается только после успешного rsync: оборванная копия никогда не выдаёт себя за целую.
- Источники могут быть удалёнными (`user@host:/var/www`), исключения задаются в синтаксисе rsync.

**Ротация**
- Правила `keep_last`, `keep_daily`, `keep_weekly` (ISO-недели), `keep_monthly`, `keep_yearly`; снимок, нужный хотя бы одному правилу, остаётся.
- `prune --dry-run` показывает, что и по какому правилу будет оставлено или удалено.
- Политику, которая удалила бы всё, slepok отказывается выполнять.

**Работа со снимками**
- `list`: сколько места добавил каждый снимок и сколько заняли бы копии без жёстких ссылок.
- `diff`: добавленные, изменённые и удалённые файлы между двумя снимками.
- `history`: все версии файла по снимкам (по смене inode) и когда файл исчез.
- `restore`: достать файл или папку в отдельный каталог; снимок можно указать началом имени, `latest` или `previous`.

**Для сервера**
- Шаблонные юниты `slepok@.service` и `slepok@.timer`: несколько независимых профилей (`/etc/slepok/home.conf`, `/etc/slepok/sites.conf`), запуск в 03:00, догоняющий запуск после выключения.
- `pre_hook` (например, дамп PostgreSQL перед копированием), `post_hook` и `on_error` с кодом ошибки, удобный для уведомления в Telegram.
- Блокировка через `flock`, проверка свободного места, `slepok check` для мониторинга: вернёт ошибку, если последний снимок старше `max_age_hours`.
- Автодополнение в bash, включая имена снимков.

## Стек

Bash 4.4+, rsync, coreutils (GNU `date`, `du`, `stat`), `flock` из util-linux, systemd. Без других зависимостей. Проверка кода: ShellCheck, тесты на чистом Bash, CI в GitHub Actions.

## Запуск

```bash
git clone https://github.com/whysafe/slepok.git
cd slepok
sudo ./install.sh
sudoedit /etc/slepok/main.conf
sudo slepok check
sudo slepok backup
sudo systemctl enable --now slepok@main.timer
```

Минимальный конфиг:

```ini
dest = /mnt/backup/slepok
source = /home/alex
source = /etc
exclude = .cache/
keep_daily = 7
keep_weekly = 4
keep_monthly = 12
```

Все ключи с пояснениями: [slepok.conf.example](slepok.conf.example). Попробовать без установки можно и от обычного пользователя: `./slepok -c ./my.conf backup`.

Повседневные команды:

```bash
slepok list
slepok diff
slepok diff 2026-10-01 latest
slepok history ~/notes/todo.md
slepok restore 2026-10-15 ~/notes/todo.md /tmp/old
sudo slepok -n prune
```

Удаление: `sudo ./install.sh --uninstall` (конфиги и снимки остаются на месте).

## Как устроено

- `slepok` — один Bash-скрипт; функции можно подключить через `source`, `main` запускается только при прямом вызове. Это позволяет тестировать ротацию и разбор конфига без rsync.
- Конфиг не исполняется через `source`, а разбирается построчно с проверкой ключей и чисел: опечатка в имени ключа останавливает работу с номером строки.
- Ротация (`plan_retention`) идёт от новых снимков к старым; для каждого правила ключ интервала — дата, ISO-неделя `date +%G-W%V`, месяц или год. Правило берёт первый снимок нового интервала, пока не наберёт лимит. Время снимка берётся из имени, поэтому результат не зависит от `mtime` папок.
- `list` использует свойство `du`: при нескольких аргументах каждый inode считается один раз, поэтому размер очередного снимка равен тому, что он добавил к предыдущим.
- `history` сравнивает inode файла в соседних снимках: та же жёсткая ссылка означает ту же версию.
- `diff` — это `rsync --dry-run --delete --itemize-changes` между двумя снимками с разбором флагов `>f+++++++++`, `>f.st…`, `*deleting`.
- Внутри снимка сохраняются полные пути источников (`rsync --relative`), поэтому несколько источников не конфликтуют, а `restore` и `history` принимают обычный путь к файлу.

## Тесты

```bash
bash tests/run.sh
shellcheck slepok install.sh tests/run.sh completions/slepok.bash
```

18 тестов: разбор конфига и ошибки в нём, ротация (дни, ISO-недели на стыке годов, месяцы, годы, несколько снимков в день), жёсткие ссылки между снимками, исключения, `diff`/`history`/`restore`, автоматическая ротация после backup, пробный режим, очистка после упавшего rsync и вызов `on_error`, отмена по `pre_hook`, блокировка параллельного запуска, `check` для устаревшей копии и установка в `DESTDIR`. Время снимков подменяется переменной `SLEPOK_NOW`. Без rsync интеграционные тесты пропускаются; в CI они обязательны.

## Автор

**whysafe** — fullstack- и Unity-разработчик, фрилансю с 2023 года.

- Сайт: [whysafe.ru](https://whysafe.ru)
- Telegram: [@yawhysafe](https://t.me/yawhysafe)
- Канал: [t.me/whysafe_official](https://t.me/whysafe_official)
- Kwork: [kwork.ru/user/whysafe](https://kwork.ru/user/whysafe)
- Почта: [hello@whysafe.ru](mailto:hello@whysafe.ru)

Лицензия MIT.
