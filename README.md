# AviaCalls

Записывает встречи в Zoom и делает транскрипт с именами говорящих. Всё локально.

## Сборка

Нужны Xcode и сертификат Apple Development (Xcode → Settings → Accounts).

```bash
scripts/bundle.sh
open build/AviaCalls.app
```

## Разрешения при первом запуске

- **Универсальный доступ** — читать список участников и состояние микрофонов в окне Zoom. При первом запуске появится системный запрос; позже нужный раздел настроек открывает пункт меню «Выдать доступ».
- **Микрофон** — запрос появится сам.
- **Запись системного звука** — запрос появится на первой встрече.

Первая транскрибация скачивает модель Whisper (около 1,6 ГБ).

## Как пользоваться

Приложение живёт в менюбаре. Запись начинается сама, когда открывается окно встречи Zoom, и заканчивается, когда оно закрывается. Результат — в `~/Documents/Meetings/`.

Zoom не показывает участникам, что идёт запись. Предупреждай их сам.

## Команды для отладки

```bash
build/AviaCalls.app/Contents/MacOS/AviaCalls --dump-ax              # снимок окна встречи в JSON
build/AviaCalls.app/Contents/MacOS/AviaCalls --record-test 20       # записать 20 секунд во временную папку
build/AviaCalls.app/Contents/MacOS/AviaCalls --transcribe <папка>   # пересобрать транскрипт встречи
```

## Настройки

```bash
defaults write com.magir.aviacalls micVoiceProcessing -bool NO   # выключить эхоподавление микрофона
defaults write com.magir.aviacalls whisperModel <имя>            # другая модель Whisper
defaults write com.magir.aviacalls myName "Имя в Zoom"           # если приложение не узнало, кто из участников ты
```
