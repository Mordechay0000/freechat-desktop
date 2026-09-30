# FreeChat — דסקטופ

פורק של **Telegram Desktop** (C++/Qt, GPL-3.0) מעל
[`owpengram-desktop-client`](https://github.com/owpengram/owpengram-desktop-client)
המוצמד ל-`d5a262f`. מחובר לשרת שלך, בלי בחירת שרת.

נבנה ורץ על **לינוקס, macOS ו-Windows**.

## התחלה

```bash
cp freechat.env.example freechat.env          # כתובת השרת, פורט, DC
./scripts/bootstrap.sh --with-submodules      # עשרות GB
./scripts/apply-overlay.sh
```

**ב-Windows מריצים את שני הסקריפטים האלה מתוך "Git Bash"** (מגיע עם Git for
Windows). אין להם מקבילה ב-PowerShell במכוון: הם אותו קוד בשלוש המערכות, ומימוש
שני היה סט באגים שני. לא WSL — checkout תחת WSL לא רואה את Visual Studio.

ואז, לפי המערכת:

```bash
./scripts/build-desktop.sh all                # לינוקס (דרך Docker) או macOS
```
```powershell
powershell -ExecutionPolicy Bypass -File scripts\build-desktop.ps1 -Stage doctor
powershell -ExecutionPolicy Bypass -File scripts\build-desktop.ps1 -Stage all
```

לפני כן, ובכל שלב, אפשר לבדוק מה חסר בלי לשנות דבר:

```bash
./scripts/build-desktop.sh doctor
```

הוא מדפיס את שרשרת הכלים (Xcode, SDK, טווח ה-deployment targets), מצב ה-Qt
שהוכן, שלמות ה-submodules ומקום בדיסק — כל אחת מהבדיקות האלה נולדה מכשל אמיתי
שעלה שעות. דרישות מלאות לפי מערכת, כולל מלכודת ה-`-vcvars_ver=14.44` ב-Windows:
**`docs/10-DESKTOP.md`**.

**הבנייה של macOS אומתה מקצה לקצה** (2026-09-30): `prepare` בנה Qt 6.11.1
בכ-30 דקות, ו-`out/Release/FreeChat.app` נוצר — אוניברסלי x86_64+arm64, 1.6GB,
חתום ad-hoc. **לינוקס ו-Windows עדיין לא הורצו** (אין docker ואין Visual Studio
בסביבה שבה נכתב הריפו); שם ה-overlay אומת בקריאת קוד, וכשל ראשון הוא כנראה פער
בשרשרת הכלים ולא overlay שבור.

## שתי אסימטריות מול אנדרואיד — שתיהן אומתו בקוד

**הדומיין עובד ישירות.** הטרנספורט הוא
`QTcpSocket::connectToHost(const QString&, int)`, ו-Qt פותר שמות בעצמו. אין
צורך ב-resolver, ושינוי IP של השרת **לא דורש בנייה מחדש**.

**תעודות עובדות בלי שורת קוד.** אין `QSslConfiguration` או `setCaCertificates`
באף מקום בעץ — כלומר ברירת המחדל של Qt, שהיא מחסן התעודות של מערכת ההפעלה.
תעודה שמותקנת במחשב נסמכת אוטומטית.

פירוט: **`docs/10-DESKTOP.md`**.

## הגדרות — `freechat.env`

קובץ אחד, **זהה בשלושת הריפואים**. כל המפתחות הם `FREECHAT_*`, וערך שמשמעותו
זהה בשני ריפואים נושא את אותו שם בשניהם — כך שאפשר להחזיק env אחד משותף
לשלושתם, וכל ריפו קורא את מה שנוגע לו ומתעלם מהשאר.

```bash
cp freechat.env.example freechat.env   # ואז לערוך
```

| מפתח | מי קורא אותו |
|---|---|
| `FREECHAT_SERVER_DOMAIN` | שרת (מפרסם), אנדרואיד (פותר ושומר), דסקטופ (Qt פותר) |
| `FREECHAT_SERVER_IP` | שרת (`TELESRV_ADVERTISE_IP`), אנדרואיד (fallback מוטמע) |
| `FREECHAT_SERVER_PORT` | שלושתם |
| `FREECHAT_SERVER_DC` | שלושתם — אי-התאמה נראית כמו חיבור שלא משלים handshake |
| `FREECHAT_SERVER_RSA_PUB` | אנדרואיד, דסקטופ — נתיב יחסי לתיקיית הפלטפורמה |
| `FREECHAT_APP_NAME`, `FREECHAT_AUTO_JOIN`, `FREECHAT_API_ID/HASH` | הקליינטים |

זה החליף את `android/branding/brand.env` ו-`desktop/branding/brand.env`, שהחזיקו
את אותו מידע בשני דיאלקטים. **זה לא היה קוסמטי:** כל אחד מהם החזיק את כתובת
השרת כמחרוזת שנכתבה ביד — IP מספרי באחד, hostname בשני — כך שהשתיים יכלו לסתור
זו את זו, וזה קרה. עכשיו שתי הצורות **נגזרות** מאותם שני ערכים, כל אחת בצורה
שהפלטפורמה שלה באמת דורשת, ולא יכולות להיפרד.

**סודות לא עוברים בקובץ הזה.** `TELESRV_POSTGRES_PASSWORD` נשאר ב-
`server/upstream/.env` שלא יוצא מהשרת; `freechat.env` מיועד להיות משותף עם
ריפואים של קליינטים, ולסיסמת מסד נתונים אין שם מה לחפש.

## איך ה-overlay עובד

הריפו הזה מחזיק **רק את הדלתא של FreeChat**. את ה-upstream הוא מוריד ל-SHA
מוצמד, ומחיל עליו קבצים חדשים ו-hooks של שורה אחת. הסיבה מדידה: ה-upstreams
מתעדכנים שבועית, וכל שורה שנערוך בתוכם היא קונפליקט מרג' עתידי.

```
upstream.pin    ה-SHA המוצמד
overlay/        קבצים חדשים שנשפכים לתוך העץ של upstream
branding/       שם, כתובת, מפתחות — נתונים, לא קוד
upstream/       ב-.gitignore. לא נכנס לריפו
```

`scripts/apply-overlay.sh` מאפס את העץ ל-SHA המוצמד לפני כל החלה, כך שהוא
אידמפוטנטי מעצם הבנייה ולא במקרה.

## תיעוד

| מסמך | תוכן |
|---|---|
| `docs/00-WHY-NOT-TEAMGRAM.md` | למה הבסיס הזה, עם הנתונים שנמדדו בקוד |
| `docs/01-ARCHITECTURE.md` | שיטת ה-overlay |
| `docs/02-ROADMAP.md` | מה בוצע ומה פתוח |
| `docs/07-UPSTREAM-SYNC.md` | איך מעדכנים upstream בלי לשבור |
| `docs/08-LICENSING.md` | מה הרישיון מחייב |
