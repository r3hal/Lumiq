# Lumiq

**[Български](#български) · [English](#english)**

---

## Български

Lumiq е приложение за камера, което помага да правите по-добре композирани снимки. Функцията **AI Shot** избира най-добрия кадър в сцената, а после ви води към него в реално време.

### Как работи

1. Насочвате телефона към сцената и натискате **AI Shot**.
2. Един намален кадър се изпраща към AI модел (Google Gemini, а при забавяне и Groq). Моделът връща обекта, рамката на най-добрия кадър, приближение и кратък съвет.
3. Телефонът следи рамката в живия образ, без интернет. Показва накъде да завъртите камерата и сам приближава.
4. Когато кадърът съвпадне с предложението, се появява **„Готово“** и можете да снимате.

### Други функции

- Нивелир, мрежа, различни пропорции (3:4, 4:5, 1:1) и няколко обектива.
- Редактор с готови визии и корекции.
- Дистанционно управление на апарат Sony през Wi-Fi.
- Автоматично обновяване на Android версията.
- Анонимно самообучение (по желание). Изпращат се само резултати, никога снимки. Сървърът извежда правила, които подобряват следващите предложения.

### Структура

| Папка | Съдържание |
|---|---|
| `android/` | Приложение за Android (Kotlin, Jetpack Compose, CameraX) |
| `Focal/` | Приложение за iPhone (SwiftUI) |
| `ai-server/` | Сървър за AI Shot и обучението (Cloudflare Worker + D1) |

### Инсталиране (Android)

Изтеглете последния `.apk` файл от [Releases](../../releases) и го отворете на телефона. Следващите версии се инсталират от самото приложение.

---

## English

Lumiq is a camera app that helps you take better-composed photos. Its **AI Shot** feature picks the best shot in the scene and then guides you to it in real time.

### How it works

1. Point the phone at the scene and tap **AI Shot**.
2. One downscaled frame is sent to an AI model (Google Gemini, with Groq as a backup when Gemini is slow). The model returns the subject, a box around the best shot, a zoom level and a short tip.
3. The phone tracks that box in the live view on-device, without the internet. It shows which way to turn the camera and zooms in by itself.
4. When the framing matches the suggestion, **Ready** appears and you take the photo.

### Other features

- Level, grid, several photo shapes (3:4, 4:5, 1:1) and multiple lenses.
- Editor with looks and adjustments.
- Wi-Fi remote control of Sony cameras.
- Automatic updates for the Android version.
- Optional anonymous learning. Only results are sent, never photos. The server turns them into rules that improve the next suggestions.

### Project layout

| Folder | Contents |
|---|---|
| `android/` | Android app (Kotlin, Jetpack Compose, CameraX) |
| `Focal/` | iPhone app (SwiftUI) |
| `ai-server/` | Server for AI Shot and learning (Cloudflare Worker + D1) |

### Install (Android)

Download the latest `.apk` from [Releases](../../releases) and open it on your phone. Later versions install from inside the app.
