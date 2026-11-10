# AGENTS.md

## Changelog

`CHANGELOG.md` ведётся по [Keep a Changelog 1.0.0](https://keepachangelog.com/en/1.0.0/).

- Любое изменение, заметное пользователю приложения, сопровождается записью в `## [Unreleased]` в том же PR. Группа: Added, Changed, Deprecated, Removed, Fixed или Security; пустые группы не пишем.
- Запись по-русски и про то, что изменилось для пользователя, а не пересказ коммита. Рефакторинг, тесты и CI без видимого эффекта в changelog не попадают. Авторов не указываем.
- При релизе `## [Unreleased]` переименовывается в `## [X.Y.Z] - YYYY-MM-DD`, над ним добавляется новый пустой `## [Unreleased]`, а внизу файла обновляются ссылки сравнения: `[Unreleased]` ведёт на `compare/vX.Y.Z...HEAD`, новая `[X.Y.Z]` на `compare/vPREV...vX.Y.Z`.
