# בחירת הבסיס — הנתונים, לא ה-README

כל המספרים כאן נמדדו בקוד עצמו ב‑28.09.2026, לא הועתקו מהבטחות שיווקיות.

## teamgram-server — נבדק ונדחה

[`teamgram/teamgram-server`](https://github.com/teamgram/teamgram-server), Apache‑2.0, Layer 228.
פרויקט פעיל ואיכותי. הסיבה לדחייה חד‑משמעית:

| פיצ'ר | מהדורה פתוחה | מהדורה מסחרית |
|---|---|---|
| צ'אט פרטי, קבוצות בסיסיות, אנשי קשר | ✅ | ✅ |
| **ערוצים ו‑megagroups** | ❌ | ✅ |
| **בוטים** | ❌ | ✅ |
| Mini‑apps | ❌ | ✅ |
| שיחות אודיו/וידאו | ❌ | ✅ |
| סטיקרים, ריאקשנים, ערכות נושא | ❌ | ✅ |
| Secret chat, 2FA, SMS, פוש | ❌ | ✅ |

שלושת הדברים שהוגדרו כעיקר — **קבוצות מלאות, ערוצים ובוטים** — כולם בצד המסחרי.
בנוסף, המחסן התפעולי שלו כבד: MySQL + Redis + etcd + Kafka + MinIO + FFmpeg.

## gramsrv — הבסיס שנבחר

[`iamxvbaba/gramsrv`](https://github.com/iamxvbaba/gramsrv), Apache‑2.0.

```
commit מוצמד : dcb893723ac8c4a4068da67f4c1a1427e06e3f7d  (26.09.2026)
כוכבים/פורקים: 152 / 61      commits: 470
קוד Go       : 627,723 שורות ב-1,788 קבצים
handlers     : 464 קבצים ב-internal/rpc
מתודות MTProto רשומות: 687
תלויות        : PostgreSQL + Redis. זה הכל.
go build      : עבר נקי ב-2m30s (אומת בסשן הזה)
```

פירוס המתודות הרשומות לפי תחום — זה מה שקובע אם פיצ'ר קיים באמת:

| תחום | מתודות | תחום | מתודות |
|---|---|---|---|
| `messages.*` | 232 | `phone.*` (שיחות, group calls, RTMP) | 36 |
| `account.*` | 105 | `stories.*` | 33 |
| `channels.*` (ערוצים, סופר‑גרופים, טופיקים) | 58 | `auth.*` | 23 |
| `payments.*` (Stars, מתנות) | 46 | `contacts.*` | 19 |
| `bots.*` | 37 | `help.*` | 15 |

קיים בקוד גם `internal/botapi` (שער Bot API), `internal/sfu` ו‑`internal/turnsrv` (מדיה
בזמן אמת), `internal/admin`. ובמיוחד: קבצי בדיקה בשם `android_compat_test.go`,
`messages_polls_tdesktop_shape_test.go`, `messages_multi_pin_android_rpc_test.go` —
כלומר התאימות לקליינטים האמיתיים נבדקת, לא רק נטענת.

## owpengram-server — נבדק כחלופה

[`owpengram/owpengram-server`](https://github.com/owpengram/owpengram-server) הוא פורק של
gramsrv (25 כוכבים, commit אחרון 15.09.2026 — 11 יום מאחור). הוא מוסיף שני דברים שווים:
נקודת קצה `/owpengram/server-info` לגילוי אוטומטי של השרת בקליינט, ופאנל אדמין.

**ההכרעה:** לבנות על gramsrv upstream (עדכני ופעיל יותר), ולהעביר אליו את
את אותה נקודת קצה בעצמנו, תחת `/freechat/server-info` — זה קובץ Go אחד ושורת
חיבור אחת. זה בדיוק מה
ש‑`server/overlay/` עושה.

## הקליינט

[`owpengram/owpengram-android-client`](https://github.com/owpengram/owpengram-android-client),
GPL‑2.0‑or‑later, commit מוצמד `4adc49b29dcfe8117cfd804131e403021df7c09a`.

- פורק של **Telegram for Android v12.10.1**, MTProto Layer 229 — כלומר הממשק והפיצ'רים
  האמיתיים של טלגרם, לא חיקוי.
- **תמיכה מולטי‑שרת מובנית**: מסך ההתחברות מציע "➕ Add server", מקלידים `host:port`
  והאפליקציה שולפת בעצמה DC id ומפתח RSA. אין צורך לתקן DC hardcoded ומפתחות ידנית —
  זו העבודה הכי מייגעת בפרויקטים כאלה, והיא כבר עשויה.
- הפלייבור `TMessagesProj_AppStandalone` הוא הבלתי‑מוגבל: **בלי Firebase ובלי תלות
  ב‑Google Play**. פוש מגיע דרך חיבור keep‑alive של האפליקציה עצמה.
- 1.3GB אחרי clone רדוד עם submodules (קוד נייטיב של טלגרם). זה נורמלי.

### מה חסר שם ו-FreeChat משלים

1. **אין סקריפט בנייה ללינוקס.** קיים רק `build-android.bat` ל-Windows.
   → `scripts/build-android.sh`.
2. **המיתוג הוא OwpenGram** ב-`gradle.properties` וב-`strings.xml`.
   → `scripts/apply-overlay.sh` + `android/branding/`.
3. **ה-keystore בקוד הוא של upstream.** חייבים keystore משלך. ראה `docs/04-ANDROID.md`.
4. **אפס de-clutter.** זו העבודה האמיתית, וזה `docs/06-DECLUTTER.md`.
