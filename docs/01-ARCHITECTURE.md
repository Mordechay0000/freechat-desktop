# ארכיטקטורה

## למה overlay ולא פורק

הדחף הטבעי הוא לפרוק (fork) את שני ה-upstreams ולערוך בתוכם. זו טעות במצב הזה,
ומשתי סיבות מדידות:

- הקליינט הוא ~1.3GB ומתעדכן **אחרי כל שחרור של טלגרם**. כל שורה שתערוך בתוכו
  היא קונפליקט מרג' עתידי, לנצח.
- השרת הוא 627k שורות Go עם 470 commits ב-9 חודשים. אותו סיפור.

לכן FreeChat מחזיק **רק את הדלתא שלו**, ואת ה-upstreams מוריד לפי SHA מוצמד:

```
freechat/                         ← הריפו הזה. קטן. רק דלתא.
├── server/
│   ├── upstream.pin                  ← ה-SHA המוצמד של gramsrv
│   ├── overlay/                  ← קבצי Go חדשים שנשפכים לתוך העץ של upstream
│   └── deploy/                   ← docker-compose, .env, systemd
├── android/
│   ├── upstream.pin                  ← ה-SHA המוצמד של owpengram-android-client
│   ├── overlay/                  ← קבצי Java חדשים (מחלקת הדגלים)
│   └── branding/                 ← שם, אייקונים, מחרוזות
└── scripts/
    ├── bootstrap.sh              ← git init + fetch --depth 1 <SHA>. אין submodules.
    ├── apply-overlay.sh          ← מעתיק overlay + מחיל hooks נקודתיים. אידמפוטנטי.
    ├── server-up.sh
    ├── build-android.sh
    └── sync-upstream.sh          ← מקדם SHA ומדווח מה נשבר

server/upstream/   ו-  android/upstream/   ← .gitignore. לא נכנסים לריפו.
```

**חוק הברזל של ה-overlay:** קובץ חדש עדיף על עריכה בקובץ קיים, תמיד.
קובץ חדש לא מתנגש במרג'. עריכה כן. כל עריכה בקובץ upstream צריכה להיות
שורה אחת שקוראת למשהו מתוך ה-overlay.

כרגע כל השכבה של השרת היא **קובץ Go אחד חדש + חיבור של שורה אחת**.

## זרימת המערכת

```
   אנדרואיד (FreeChat, פורק Telegram 12.10.1)
        │
        │  MTProto 2.0 over TCP  (obfuscated2 / WebSocket, אותה פורט)
        │  GET /freechat/server-info  ← גילוי עצמי: DC id + מפתח RSA
        ▼
   gramsrv  :8080
        ├── internal/mtprotoedge   transport, handshake, sessions, RPC dispatch
        ├── internal/rpc           687 מתודות MTProto
        ├── internal/app/help      ← help.getAppConfig  ★ מנוף ה-de-clutter
        ├── internal/botapi        שער Bot API
        ├── internal/sfu + turnsrv מדיה בזמן אמת (שיחות, group calls)
        ├── internal/store         PostgreSQL
        └── internal/admin         פאנל ניהול
        │
        ├──► PostgreSQL   מצב, outbox
        ├──► Redis        נוכחות, פוש, בקרה
        └──► דיסק / S3    מדיה
```

## הגדרות: קובץ אחד לשלושת הריפואים

`freechat.env` בשורש, זהה בשלושת הריפואים. כל המפתחות `FREECHAT_*`, וערך שמשמעותו
זהה בשני ריפואים נושא **אותו שם** בשניהם — כך שאפשר להחזיק env אחד משותף, וכל
ריפו קורא את מה שנוגע לו.

זה החליף שני קבצי `brand.env` שהחזיקו את אותו מידע בשני דיאלקטים, ומדובר בתיקון
באג ולא בסידור. כל אחד מהם החזיק את כתובת השרת כמחרוזת שנכתבה ביד — IP מספרי
באחד, hostname בשני — ולכן הן יכלו לסתור זו את זו. עכשיו **שתיהן נגזרות**
מ-`FREECHAT_SERVER_IP` / `FREECHAT_SERVER_DOMAIN` / `FREECHAT_SERVER_PORT`, כל
אחת בצורה שהפלטפורמה שלה דורשת:

| | מקבל | למה |
|---|---|---|
| אנדרואיד | `IP:port` | `inet_pton` ב-`ConnectionSocket.cpp:586` לא פותר שמות |
| דסקטופ | `domain:port` | `QTcpSocket::connectToHost` פותר בעצמו |
| שרת | `TELESRV_LISTEN`, `TELESRV_ADVERTISE_IP`, `TELESRV_DC` נגזרים | הטוען של gramsrv מקבל `TELESRV_*` בלבד ומפיל את השרת על כל מפתח אחר |

**סודות לא עוברים דרכו.** `TELESRV_POSTGRES_PASSWORD` נשאר ב-`server/upstream/.env`
שלא יוצא מהשרת, כי `freechat.env` מיועד להיות משותף עם ריפואים של קליינטים.

**נטען בפרסור, לא ב-source.** `set -a; . file` מריץ את הקובץ כסקריפט, ולכן השורה
`FREECHAT_SERVER_DESCRIPTION=Private node` פירושה "הרץ את הפקודה `node`" — REPL
שממתין ל-stdin. זה קרה כאן פעמיים, והתקיעה תלויה במה ש-stdin במקרה, כלומר עובר
בבדיקה ונתקע בשימוש אמיתי. `scripts/lib/load_env.sh` הוא הפרסר היחיד, ובדיקה
ב-selftest מוודאת שלא נשאר אף source.

## ★ המנוף המרכזי: help.getAppConfig

זו הנקודה החשובה ביותר במסמך הזה.

הקליינט של טלגרם קורא **212 מפתחות קונפיגורציה** מהשרת (נמדד ב-`MessagesController.java`)
ולפיהם מדליק ומכבה פיצ'רים שלמים בממשק. `gramsrv` מגיש כרגע **92** מהם
(`internal/app/help/service.go`, 308 שורות).

המשמעות: חלק ניכר מ"הבלגן" של טלגרם נכבה **מהשרת**, בלי לגעת בקליינט בכלל —
אפס עלות מרג', אפס בנייה מחדש, שינוי מיידי לכל המשתמשים.

דוגמאות למפתחות שהקליינט מכבד ושכדאי לבדוק:
`stories_posting`, `stargifts_blocked`, `enable_gifts_in_profile`,
`premium_purchase_blocked`, `sponsored_links_inapp_allow`, `dialog_filters_enabled`,
`giveaway_gifts_purchase_available`, `autoarchive_setting_available`.

הרשימה המלאה וההכרעות: [`06-DECLUTTER.md`](06-DECLUTTER.md).

## שלוש שכבות ה-de-clutter, בסדר הנכון

| שכבה | איפה | עלות מרג' | כשמשתמשים |
|---|---|---|---|
| 1. appConfig | `server/overlay/internal/app/help/` | **אפס** | ברירת מחדל. תמיד לנסות קודם |
| 2. דגל בקליינט | `android/overlay/.../FreeChatFlags.java` | נמוכה (קובץ חדש + hook) | טאבים, סעיפי הגדרות, פריטי תפריט |
| 3. הסרת קוד | עריכה ב-upstream | גבוהה | מוצא אחרון בלבד |

כל שימוש בשכבה 2 או 3 **חייב** רשומה ב-[`05-REMOVED-FEATURES.md`](05-REMOVED-FEATURES.md).
זה לא בירוקרטיה: בלי היומן הזה, בעוד חצי שנה לא תדע למה פיצ'ר חסר ואם בטוח להחזיר.
