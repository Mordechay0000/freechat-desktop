# עדכון upstream

## הרעיון

`scripts/sync-upstream.sh` מקדם pin אחד, מחיל מחדש את ה-overlay, בונה, מריץ טסטים,
ורק אם **הכל** עבר — מעדכן את ה-pin. אם משהו נכשל, ה-pin נשאר איפה שהיה
והבילד שלך ממשיך לעבוד.

```bash
./scripts/sync-upstream.sh server            # ל-HEAD של הברנץ'
./scripts/sync-upstream.sh server <commit>   # ל-commit מסוים
./scripts/sync-upstream.sh android
```

## כשהוא נכשל — וזה יקרה

הכשל השכיח הוא `hook: ...: anchor not found -- upstream moved`. פירושו: השורה
ב-upstream שה-overlay נתלה עליה שונתה. זה לא באג, זו המערכת עושה את עבודתה —
העדפנו כשל רועש על hook מנוחש בתוך צנרת MTProto.

הטיפול:

1. **מצא לאן השורה עברה.** למשל עבור ה-hook של appConfig:
   ```bash
   grep -rn "appConfigCache" server/upstream/internal/app/help/service.go
   ```
2. **עדכן את ה-anchor** ב-`scripts/apply-overlay.sh`. את ה-anchor, לא את הקוד ב-upstream.
3. **אם הפונקציה הוחלפה לגמרי** — הגיע הזמן לבדוק אם ה-overlay עוד נחוץ. לפעמים
   upstream מימש בעצמו את מה שכתבת. זה התרחיש הטוב.
4. `./scripts/sync-upstream.sh server` שוב.

## ה-hooks הקיימים — שניים בלבד

| קובץ | anchor | למה |
|---|---|---|
| `internal/mtprotoedge/server.go` | `Handler:           websocketRouteHandler(wsHandler, s.websocketOrigins),` | לעטוף את ה-mux כדי להגיש `/freechat/server-info` |
| `internal/app/help/service.go` | `return s.appConfigCache` | להעביר כל קריאת appConfig דרך שכבת ה-de-clutter |

שניהם ייחודיים בקובץ שלהם — נבדק. `hook.py` נכשל אם anchor מופיע פעמיים,
במקום לנחש איזה מהם התכוונת.

**שמור על המספר הזה קטן.** שלושה hooks זה נוח. חמישה-עשר זה פורק שמעמיד פנים
שהוא overlay, וכל סינק יהפוך ליום עבודה.

## תזמון

- **שרת**: `gramsrv` עושה ~50 commits בחודש. סינק חודשי הוא איזון סביר.
- **קליינט**: זז אחרי שחרורי טלגרם. סינק כשיוצא שחרור שאכפת לך ממנו, לא לפי לוח זמנים.
- **אחרי כל סינק** — הרם והתחבר במכשיר אמיתי. הטסטים לא מכסים handshake מקצה לקצה.
