# הקליינט לדסקטופ

פורק של **Telegram Desktop** (C++/Qt), GPL-3.0, מ-`owpengram-desktop-client`
המוצמד ל-`d5a262f`. אותה שיטת overlay כמו באנדרואיד: קובץ חדש + hooks של שורה.

## שתי אסימטריות מול אנדרואיד — שתיהן אומתו בקוד

**1. הדומיין עובד ישירות.** הטרנספורט עובר ב-
`QTcpSocket::connectToHost(const QString&, int)`
(`mtproto/details/mtproto_tcp_socket.cpp:54`), ו-Qt פותר שמות מתחם בעצמו.
באנדרואיד השכבה הנייטיבית משתמשת ב-`inet_pton` שלא פותר DNS, ולכן שם מוטמע IP
והדומיין נפתר ב-Java. כאן **אין צורך ב-resolver, אין cache, ושינוי IP של השרת
לא דורש בנייה מחדש** — ה-DNS מטפל בזה.

**2. תעודות עובדות בלי שורת קוד.** אין `QSslConfiguration`, `setCaCertificates`
או `addCaCertificate` באף מקום בעץ, וה-`.pem` היחיד הוא מפתח חתימת העדכונים ולא
מחסן CA. כלומר ברירת המחדל של Qt חלה, והיא **מחסן התעודות של מערכת ההפעלה**.
תעודה שמותקנת במחשב נסמכת אוטומטית.

זה ההיפך מאנדרואיד, שם הפלטפורמה מתעלמת במכוון מתעודות שהמשתמש התקין ולכן היה
צריך `network_security_config`.

> **שים לב:** זה מחסן ה-OS. אם תתקין CA רק ב-Firefox — לו יש מחסן NSS נפרד —
> הדסקטופ לא יראה אותו. באובונטו: הקובץ ל-`/usr/local/share/ca-certificates/`
> ואז `sudo update-ca-certificates`.

## מה ה-overlay עושה

| | |
|---|---|
| `freechat/freechat_builtin.h` | header-only. הרשומה המוטמעת של השרת, וסינון הרשימה |
| hook ב-`ListServers()` | מחליף את הרשימה: FreeChat בלבד + שרתים שהוספת |
| hook ב-`ServerSelectWidget::activate()` | **עוקף את מסך בחירת השרת** ומצטרף ישר |

ה-header הוא header-only במכוון: הוספת `.cpp` מחייבת עריכה ברשימת המקורות של
`Telegram/CMakeLists.txt` — עוד קובץ upstream למרג' בכל עדכון.

ה-hook של ה-auto-join יושב **בתוך** `ServerSelectWidget` כדי שיוכל לקרוא ל-
`proceedJoin()` הפרטי. כך `ApplyServerToAccount`, ה-`ConnectingBox` עם ה-Cancel
שלו, ההמתנה לחיבור והמסירה לשלב הבא נשארים הקוד הבדוק של upstream.
hook אחד מכסה גם הפעלה ראשונה (דרך `StartWidget`) וגם הוספת חשבון (דרך
`EnterPoint::ServerSelect` ב-`window_controller`).

## הניקוי

480 מופעים ב-40 קבצים: `namespace Owpengram`, מודול השרתים ושלושת ה-boxes,
מזהה החבילה, 49 מפתחות `lng_`, קבצי ה-JSON, צלילי ההתראה, `Resources/OwpenGram`,
והסכמה `owpg://`. מפתח ה-RSA וה-IP של הצומת שלהם רוקנו. רשומות המקורות
ב-`CMakeLists.txt` עודכנו בהתאם.

`scripts/lib/purge_branding_desktop.py` יוצא בשגיאה אם נשאר מופע אחד או נתיב
אחד בשם שלהם — במקום לדווח הצלחה על שינוי שם חצי-גמור.

## בנייה — שלוש הפלטפורמות

הקליינט לדסקטופ נבנה ורץ על **לינוקס, macOS ו-Windows**. השרת לא — הוא לינוקס
בלבד, במכוון (`scripts/install-service.sh` מסרב על שתי האחרות ומפנה לחלופה).

### מה צריך להתקין, לפי מערכת

| | לינוקס | macOS | Windows |
|---|---|---|---|
| קומפיילר | מסופק בקונטיינר של upstream | **Xcode מלא**, לא רק CLT | Visual Studio 2022/2026 + toolset **14.44** |
| git | חבילת המערכת | `xcode-select --install` | [Git for Windows](https://git-scm.com/download/win) |
| bash | יש | יש | **Git for Windows** — ראה למטה |
| Python 3 | חבילת המערכת | מגיע עם CLT | python.org, לסמן "Add to PATH" |
| נוסף | `docker`, `poetry` | `brew` | — |
| דיסק | ~60GB | **~35GB ל-prepare ועוד ~10GB לבנייה** | ~60GB |

### שלב מקדים משותף — וההערה שחייבת להיאמר על Windows

```bash
./scripts/bootstrap.sh desktop --with-submodules   # עשרות GB
./scripts/apply-overlay.sh desktop
```

**שני אלה הם bash, וגם ב-Windows מריצים אותם ב-bash — מתוך "Git Bash".** אין
להם מקבילה ב-PowerShell, וזו החלטה: הם אותו קוד בשלוש המערכות, ומימוש שני היה
סט באגים שני. Git for Windows מספק את ה-bash שמריץ אותם, וממילא צריך אותו
לבנייית Telegram Desktop.

**לא WSL בשלב הזה.** checkout תחת WSL לא רואה את התקנת Visual Studio שלך,
והבנייה צריכה MSVC בצד של Windows.

`scripts\build-desktop.ps1` בודק שיש `bash` ו-Python 3 עובד לפני שהוא מתחיל,
כי הודעות השגיאה שלו עצמו מפנות אותך להריץ `bash scripts/...` — וזו הוראה מבלבלת
לקבל במכונה שאין בה bash.

### `python3` לא קיים ב-Windows, וזה כבר מטופל

`apply-overlay.sh` קורא ל-Python **30 פעם**, והתקנה סטנדרטית מ-python.org
מספקת `python.exe` ו-`py.exe` ולא `python3`. כלומר כל 30 הקריאות נכשלו שם,
ו-`build-desktop.ps1` בדק `python` בעוד הסקריפט שהוא מפנה אליו דרש `python3` —
השניים לא הסכימו והמסלול נשבר בשלב השני.

`scripts/lib/portable.sh` פותר את השם בזמן ריצה — `python3`, אחר כך `python`,
אחר כך `py -3` — ו**שואל את המפרש מה הגרסה שלו** במקום להסיק מהשם, כי `python`
שהוא Python 2 גרוע מהיעדר python: הוא רץ ואז נכשל בתוך סקריפט.

### `api_id` / `api_hash` — לא צריך להירשם

`configure` דורש את שניהם בכל שלוש הפלטפורמות. **gramsrv לא מאמת אותם** —
`internal/rpc/auth.go:874` אומר במפורש שאין רישום אפליקציות והערכים רק נזכרים
לטלמטריה. לכן הערכים שב-`freechat.env` מספיקים לצומת פרטי, ואין
עניין עם my.telegram.org.

### לינוקס — דרך Docker

upstream בונה לינוקס **בתוך קונטיינר משלו**, לא בשרשרת הכלים של המכונה:

```bash
./scripts/build-desktop.sh prepare     # בונה את הדימוי tdesktop:centos_env. שעות
./scripts/build-desktop.sh build
```

דורש `docker` ו-`poetry`.

### macOS

```bash
./scripts/build-desktop.sh doctor      # מה חסר, בלי לשנות דבר
./scripts/build-desktop.sh prepare     # brew (רק מה שחסר) + prepare/mac.sh
./scripts/build-desktop.sh configure
./scripts/build-desktop.sh build
```

דורש **Xcode מלא**, לא רק command line tools. הבנייה עוברת דרך
`cmake --build`, כך שהיא עובדת בין אם `configure.sh` בחר Xcode או ninja, ובלי
לפתוח את ה-GUI. לחלופין: `out/Telegram.xcodeproj` ב-Xcode.

**מדידות מהרצה אמיתית** (2026-09-30, 10 ליבות): `prepare` — כ-30 דקות, שיא של
~35GB (26GB עץ בנייה של Qt ועוד התקנה של 8.3GB). `configure` — ~70 שניות.
`build` — כ-30 דקות, `out/` 9.4GB, והתוצר `out/Release/FreeChat.app` —
אוניברסלי x86_64+arm64, 1.6GB, חתום ad-hoc.

#### תאימות: Xcode מול ה-deployment target

Xcode מסרב לבנות למערכת שה-SDK שלו לא תומך בה, ובשגיאה מפורשת:

```
error: The macOS deployment target 'MACOSX_DEPLOYMENT_TARGET' is set to 12.0,
but the range of supported deployment target versions is 12.0 to 27.0.99.
```

הטווח הזה הוא תכונה של ה-SDK ולא קבוע: באותה מכונה הוא עבר מ-`12.0 ומעלה`
(Xcode 27 בטא) ל-`10.13 עד 26.5.99` (Xcode 26.6) בתוך יום. לכן
`FREECHAT_MACOS_DEPLOYMENT_TARGET` (ברירת מחדל `12.0`) **נפתר מול ה-SDK המותקן**
במקום להילקח כמובן מאליו: הטווח נקרא מ-`SDKSettings.plist` — בדיוק הקובץ ש-Xcode
קורא — ואם הערך מחוץ לטווח הוא מותאם לגבול הקרוב, עם הסבר מה זה משנה:

- **מתחת לרצפה** — Xcode לא יבנה בכלל, אז המטרה עולה לרצפה. זה **מוותר על תמיכה
  במק ישן יותר**, וההודעה אומרת זאת במפורש.
- **מעל התקרה** — אין SDK למערכת חדשה יותר, אז המטרה יורדת לגרסת ה-SDK עצמו.

שני הצדדים — `prepare.py` עבור הספריות ו-`CMAKE_OSX_DEPLOYMENT_TARGET` עבור
האפליקציה — קוראים לאותו פותר, ואם `prepare.py` נכתב עם ערך אחר (למשל Xcode
הוחלף בינתיים) `build` נעצר עם הסבר, במקום להיכשל בקישור בתוך ספרייה.

**ו-`sudo` לא רץ מכאן.** `xcode-select -s` דורש סיסמה, מה שהופך בנייה לא-אינטראקטיבית
לתלייה, ולכן הסקריפטים בודקים `xcodebuild -version` ומדפיסים את הפקודה שצריך
להריץ ידנית אם Xcode לא נבחר. `xcode-select -p` שמצביע נכון הוא המצב הרגיל ואז
אין מה להריץ.

#### "Neither Qt6 nor Qt5 is found" — מה זה אומר

זו שגיאת cmake, והיא מתארת סימפטום ולא סיבה. במאק האפליקציה מקשרת Qt **סטטי**
ש-`prepare.py` מתקין ל-`desktop/Libraries/local/Qt-<version>`, ולכן המסר אומר
שההתקנה הזו חסרה או חצי-כתובה. בדרך כלל היא חסרה לגמרי: שלב ה-Qt של `prepare.py`
מתחיל ב-`rm -rf qt_<version>`, כך שהרצה שנקטעת (דיסק מלא, Ctrl-C, רשת שנופלת)
משאירה אפס Qt — ומפתח ה-cache, שנכתב רק בהצלחה, לא נכתב. `build-desktop.sh`
בודק את זה לפני configure ומדפיס את הסיבה והתיקון במקום להעביר הלאה את המסר
של cmake. התיקון: `./scripts/build-desktop.sh prepare` (~30 דקות, ~35GB פנויים).

#### בדיקות שהסקריפטים מריצים לבד

| בדיקה | מה היא תופסת |
|---|---|
| Xcode מלא + טווח ה-deployment targets | `sudo xcode-select` שנדרש, ומטרה ש-Xcode לא יבנה |
| התקנת Qt מוכנה (`Qt6Config.cmake`) | "Neither Qt6 nor Qt5 is found", לפני שהוא מופיע |
| שלמות ה-submodules (`git submodule status`) | הורדה שנקטעה באמצע, שנכשלת בשעות שאחריה |
| חתימת שרשרת הכלים של הספריות | ספריות סטטיות שנבנו עם SDK אחר (`_dup3` מול SDK 27) |
| מקום בדיסק מול המדידה | בנייה שנגמרת באמצע — ומתחילה מאפס בהרצה הבאה |

`doctor` מריץ את כולן ומדפיס דוח, בלי לשנות דבר; שאר השלבים מריצים את שלהן
ומפסיקים עם הסבר. כל אחת מהן זולה באותם סדרי גודל של ההמתנה שהיא חוסכת.

#### ה-submodules לעולם לא "חצי"

`git submodule update` אידמפוטנטי — הוא מושך מה שחסר ומדלג על מה שקיים — ולכן
התיקון של הורדה שנקטעה הוא פשוט להריץ אותו שוב. מה שהוא **לא** עושה זה לדווח אם
התוצאה שלמה: clone שנהרג באמצע משאיר תיקייה שקיימת וריקה, והבנייה נכשלת שעות
אחר כך בתוך header שמישהו מחק בלי כוונה. לכן `bootstrap.sh --with-submodules`
מריץ אחריו `git submodule status --recursive` (git עצמו עונה: `-` לא מאותחל,
`+` קומיט אחר מזה שנרשם) ומסרב להכריז הצלחה על עץ שהוא רק חלקית שם. `prepare`
בודק את אותו הדבר עם `repair`, שמשלים גם קבצים שנמחקו מתת-מודול מאותחל —
מקרה שבו `git submodule update` לא עושה כלום, כי הוא משווה קומיטים ולא worktree.

### Windows

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build-desktop.ps1 -Stage doctor
powershell -ExecutionPolicy Bypass -File scripts\build-desktop.ps1 -Stage prepare
powershell -ExecutionPolicy Bypass -File scripts\build-desktop.ps1 -Stage configure
powershell -ExecutionPolicy Bypass -File scripts\build-desktop.ps1 -Stage build
```

`-Stage doctor` (כמו ב-macOS) מדפיס מה קיים ומה חסר ולא משנה דבר: PowerShell,
סביבת Visual Studio, git/bash/Python 3, התקנת ה-Qt שהוכנה, שלמות ה-submodules
ומצב `out\`. הוא רץ **לפני** הבדיקות שנכשלות בכוונה, כי התפקיד שלו הוא לדווח על
מה שחסר ולא למות עליו.

#### ארכיטקטורה — ב-Windows אין "universal"

אין ב-Windows קובץ fat כמו ב-macOS: אין `lipo`, ו-ARM64X — PE אחד שנושא גם תצוגת
Arm64 וגם תצוגת x64 — רץ **רק** על Windows on Arm, כך שהוא לא מחליף בנייה ל-x64.
בנייה אחת היא ארכיטקטורה אחת, ו-upstream תומך בשלוש, שכל אחת מהן נכתבת אחרת בכל
כלי:

| `-Arch` | `Platform` (prepare.py) | `configure.bat` | `msbuild` | ספריות |
|---|---|---|---|---|
| `x86` | `x86` | `x86` | `Win32` | `Libraries\` |
| `x64` | `x64` | `x64` | `x64` | `Libraries\win64\` |
| `arm64` | `arm64` | `arm` | `ARM64` | `Libraries\` |

ברירת המחדל, `-Arch auto`, קוראת את `$env:Platform` — בדיוק מה ש-prepare.py קורא
— כך שסביבת Visual Studio קובעת את הארכיטקטורה של הספריות **ואת זו של האפליקציה**
יחד. בקשה מפורשת של x64 כשה-prompt הוא ARM64 הייתה בונה את הספריות לארכיטקטורה
אחת ואת האפליקציה לשנייה, וזה נכשל בקישור שעות אחר כך. לכן ה-`doctor` מדפיס איזו
ארכיטקטורה נבחרה, מאיפה, ואיך היא נכתבת בכל אחד מהכלים.

**מכאן ש"universal" ב-Windows פירושו שתי בנייות** (x64 ו-arm64), כל אחת מה-prompt
שלה ועם `-Stage prepare` משל עצמה — ואז שני קבצים, לא אחד. כדאי לדעת גם ש-x64 הוא
היחיד עם עץ ספריות נפרד: `x86` ו-`arm64` חולקים את `Libraries\` **עם בנייה של
macOS**, וכל שלב של prepare מתחיל במחיקת התיקייה שלו שם. ה*התקנה* של macOS
(`Libraries\local`) אינה תיקיית stage ולכן שורדת — אפליקציה שכבר נבנתה למאק
תמשיך לעבוד, ובנייה חוזרת שלה תצטרך לבנות מחדש את אותן ספריות. לשני העולמות
במקביל, בלי הפתעות: שני clones. (`doctor` מציג את זה כשורה משלו, ו-`prepare`
מזהיר לפני שהוא נוגע במשהו.)

**המכשלה שתופסת כל אחד:** הפקודות חייבות לרוץ בטרמינל שבו אותחלה סביבת
Visual Studio **עם ה-toolset הישן**. ברירת המחדל של VS 2026 היא `v145` שלא
תומך ב-Windows 7, ש-Telegram Desktop עוד מכוון אליו — ולכן upstream דורש
`-vcvars_ver=14.44`:

```bat
%comspec% /k "C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat" -vcvars_ver=14.44
```

הסקריפט בודק `$env:VSINSTALLDIR` ומסרב אם הסביבה לא אותחלה, כי בלעדיה
`prepare\win.bat` ו-`configure.bat` נכשלים בלי להזכיר את הסיבה.
דורש גם Git ו-Python 3.10 ב-PATH.

#### למה נראה כאילו הסקריפט לא עשה כלום

`build-desktop.ps1` כותב ל-stdout ול-stderr ישירות, ולא דרך `Write-Host`. זו לא
בחירת סגנון: `Write-Host` כותב אל ה-console host ולא אל ה-stdout של התהליך,
ושני מצבים שגרתיים כאן מאבדים בדיוק את הפלט הזה:

- **Git Bash (mintty)** — קונסולה מסוג pty, וכתיבה דרך ה-console host לא מגיעה
  אליה. הסקריפט נכשל באחת הבדיקות המוקדמות, והחלון נשאר ריק — כלומר הפלט לא
  "לא הודפס", הוא הודפס למקום שאין לו מסך.
- **הפניית פלט** — ב-Windows PowerShell 5.1 (זה `powershell.exe` שבכל התקנת
  Windows) `> log.txt` לוכד את stdout **ולא** את `Write-Host`: המסך הראה טקסט
  והלוג יצא ריק. PowerShell 7 שינה זאת, וזו הסיבה שדווקא ב-pwsh זה נראה תקין.

נוסף `trap` שמדפיס כל שגיאה שעולה ל-stderr, כי גם הרינדור של שגיאה ב-PowerShell
הוא כתיבה ל-console host; בלעדיו קריסה שקטה באותה סביבה בדיוק. המחיר הוא צבעים,
והוויתור מכוון: בנייה שאי אפשר לקרוא או לתעד גרועה מצבע.

#### התקנת ה-Qt לפי ארכיטקטורה — מלכודת שנראית כמו "אין Qt"

`prepare\win.bat` מתקין את ה-Qt הסטטי תחת `Libraries\win64\Qt-<version>` עבור
x64, ותחת `Libraries\Qt-<version>` עבור x86 — ואותו דבר עושה cmake של upstream
(`variables.cmake`: `build_win64` → `../Libraries/win64`). לכן עץ שהוכן ל-x86
**בלתי נראה** ל-build של x64, והתוצאה זהה לחלוטין ל-"Neither Qt6 nor Qt5 is
found". הסקריפט בודק את השורש של הארכיטקטורה המבוקשת, ואם הוא מוצא Qt בשורש
השני הוא אומר זאת במפורש במקום לתת ל-cmake לנחש.

### בנייה לשתי הפלטפורמות מאותה תיקייה

אותו checkout יכול לשמש גם ל-macOS וגם ל-Windows. אין צורך להוריד שוב את
ה-submodules ולא להחיל שוב את ה-overlay:

| | מקום |
|---|---|
| המקורות וה-submodules | `desktop/upstream` — משותפים |
| ספריות macOS | `desktop/Libraries/local`, וה-Qt ב-`local/Qt-6.11.1` |
| ספריות Windows | x64: `desktop/Libraries/win64` (Qt ב-`win64/Qt-6.11.1`); x86 ו-arm64: `desktop/Libraries` |
| פלט הבנייה | `desktop/upstream/out` — **משותף, ולכן לפלטפורמה אחת בכל רגע** |

מה שכן צריך: `-Stage prepare` בצד Windows. זו בנייה **נפרדת** של Qt, FFmpeg,
OpenSSL ו-‎30 ספריות נוספות מה-build של macOS (‎~35GB משלה, שעות) — היא לא נוגעת
בספריות של macOS כלל. ומה שחוזר על עצמו: `out/`. ה-configure של Windows יזרוק
את `out/` שנבנה ב-macOS ויבנה מחדש, ובחזרה; החותמת של כל פלטפורמה שונה (`...|mac|12.0`
מול `...|x64`), כך שההחלפה קורית פעם אחת, בהצהרה מפורשת, ולא כמצב לא-עקבי. אם
שתי הבנייות צריכות להתקיים במקביל — שני clones.

היוצא מן הכלל לשורה "ספריות Windows" שלמעלה: ל-`arm64` (ול-`x86`) אין עץ נפרד,
והוא חולק את `Libraries\` עם ה-stages של macOS — ראו "ארכיטקטורה" למעלה.

`bootstrap.sh --with-submodules` ו-`apply-overlay.sh` **לא** צריך להריץ שוב:
ה-submodules כבר בעץ והעטיפה כבר הוחלה. הם אידמפוטנטיים, כך שהרצה חוזרת לא
מזיקה — אבל היא מאפסת את עץ המקורות, ולכן גם את הבנייה האינקרמנטלית שאחריה.

## הרצה — מה שתופגש בו בכל מערכת

| | איפה הבינארי | מה חוסם בהרצה ראשונה |
|---|---|---|
| לינוקס | `desktop/upstream/out/` | כלום |
| macOS | `desktop/upstream/out/` (או `out/Telegram.xcodeproj` ב-Xcode) | **Gatekeeper** — בנייה לא חתומה |
| Windows | `desktop/upstream/out/Release/` | **SmartScreen** — בינארי לא מוכר |

**macOS:** בנייה מקומית לא חתומה ב-Developer ID, ולכן לחיצה כפולה תיחסם. פתיחה
ראשונה: קליק ימני → Open → Open, או `xattr -dr com.apple.quarantine <path>.app`.
זו התנהגות של המערכת, לא באג בבנייה.

**Windows:** SmartScreen יציג "Windows protected your PC" — More info → Run anyway.
נעלם אם תחתום את הבינארי בתעודה משלך.

**תעודות אבטחה — עובד בשלושתן בלי שורת קוד.** אין `QSslConfiguration` ואין
`setCaCertificates` באף מקום בעץ, כלומר ברירת המחדל של Qt, שהיא מחסן התעודות של
מערכת ההפעלה: Keychain ב-macOS, Certificate Store ב-Windows, ה-CA bundle של
המערכת בלינוקס. תעודה שהתקנת במחשב נסמכת אוטומטית.

**וזה לא נוגע ל-MTProto בכלל.** ההצפנה שם היא AES-IGE עם מפתח ה-RSA של השרת
(`freechat.env` → `FREECHAT_SERVER_RSA_PUB`), בלי תעודות ובלי TLS. התעודות משנות
רק ל-HTTPS שהאפליקציה עושה בצד.

## מה אומת ומה לא, במפורש

**macOS הורצה מקצה לקצה** (2026-09-30): `prepare` בנה Qt 6.11.1 סטטי (Release +
Debug, `x86_64;arm64`), `configure` עבר, ו-`build` הפיק
`out/Release/FreeChat.app` — אוניברסלי, 1.6GB, חתום ad-hoc, `codesign --verify`
עובר, והבינארי לא תלוי בשום ספרייה שאינה של המערכת (Qt סטטי). המספרים למעלה.

מה שזה לא מכסה: ההרצה עצמה לא נבדקה (האפליקציה לא הופעלה), ו**לינוקס ו-Windows
עוד לא הורצו** — אין docker ואין Visual Studio בסביבה הזו. שם ה-overlay אומת
בקריאת קוד והסקריפטים בקריאת התיעוד של upstream.

**מה כן אומת קודם:** `apply-overlay.sh desktop` רץ בהצלחה, גזר את הכתובת נכון
(`freechat.forum-dev.com:8080` — hostname, בניגוד לאנדרואיד), ועובר דרך כל 30
קריאות ה-Python בפותר השמות. אידמפוטנטיות שלושת ה-overlays מאומתת ב-selftest,
וכמוה גם לוגיקת התאימות החדשה (טווח ה-deployment targets, זיהוי Qt חצי-מותקן,
ושלמות submodules) — בלי Xcode ובלי רשת.

**`build-desktop.ps1`: מתפרסר נקי ב-PowerShell 7.4.6** (ה-parser של PowerShell
עצמו, 0 שגיאות), ושני הבלוקים הלוגיים שלו — קריאת `freechat.env` וזיהוי Python —
**הורצו** בשלושה מצבים: `python3` קיים, רק `py -3` (התקנת python.org), ובלי Python
בכלל. מה שלא נבדק: החלקים שתלויים בנתיבי Windows וב-Visual Studio, שלא ניתנים
להרצה על לינוקס. `selftest.sh` מפרסר כל `.ps1` כש-`pwsh` מותקן.

שלושה באגים נמצאו בו בקריאה חוזרת לפני שהיה לו parser בכלל:

1. `$args` הוא משתנה אוטומטי שמור ב-PowerShell — שינוי שם.
2. הוא בדק `python` בעוד `apply-overlay.sh` דרש `python3`, שלא קיים ב-Windows.
3. הוא הפנה להריץ `bash scripts/...` בלי לבדוק שיש bash בכלל.

### סקריפטי ה-bash: מה נבדק בכל מערכת

| | איך נבדק | תוצאה |
|---|---|---|
| לינוקס | הרצה ישירה | selftest מלא עובר |
| macOS | **bash 3.2.57 אמיתי** (זה ה-`/bin/bash` של מק) + PATH בלי `sha256sum` ובלי `timeout` | selftest מלא עובר |
| Windows | `uname` שמדווח `MINGW64_NT` + PATH בלי `python3` — פעם עם `python`, פעם רק עם `py -3` | selftest מלא עובר |

מה שלא ניתן לדמות כאן: הסמנטיקה של `sed` ו-`grep` של BSD, ו-MSYS עצמו. את
הראשון כיסתה סריקה (שני ביטויים שעבדו רק ב-GNU תוקנו); את השני — אתה, בהרצה
הראשונה.

כשל ראשון הוא כנראה פער בשרשרת הכלים או שגיאת כתיב בסקריפט, ולא overlay שבור.
ההוראות המחייבות הן של upstream: `desktop/upstream/docs/building-{linux,mac,win}.md`.
