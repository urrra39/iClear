# iClear (avvalgi nomi iClean)

[![CI](https://github.com/urrra39/iClear/actions/workflows/ci.yml/badge.svg)](https://github.com/urrra39/iClear/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

> **1.0.0 versiyasi (2026-10-02).** Bitta Mac'da (Apple M3 Pro, 18 GB, macOS 27.0.1) laboratoriya ishga
> tushirgan haqiqiy ilovalar (Chrome, VS Code, TextEdit, Preview) va simulyatorlar bilan
> tasdiqlangan, hech qachon shaxsiy akkauntlar bilan emas. 7 kunlik uzoq sinov (soak)
> 2026-10-01 20:29 UTC dan beri davom etmoqda; natijalari ma'lumot yig'ilgach e'lon qilinadi.
> iClear **Kuzatish rejimida** boshlanadi, u faqat nima qilgan bo'lardi, shuni yozib
> boradi. Avvalgi nomi iClean; "iClean dan o'tish" bo'limiga qarang.

iClear xotirasi tugayotgan Mac'da fonda bo'sh turgan ilovalarni pauza qiladi va siz
qaysi biriga qaytsangiz, uni o'sha zahoti davom ettiradi. Pauza qilingan ilova
oynalari, tablari va saqlanmagan holatini saqlab qoladi. U shunchaki ishlashdan
to'xtaydi, shunda macOS u bilan RAM uchun kurashish o'rniga uning xotirasini siqishi
yoki svopga chiqarishi mumkin. Xotira bosimi me'yorida bo'lsa, iClear hech narsa
qilmaydi.

**iClear hech qachon fayllaringizni o'chirmaydi.** U faqat pauza qiladi, davom ettiradi
va maslahat beradi. Kesh, log yoki yuklanmalarni o'chirmaydi. Apple Inc. bilan bog'liq
emas va shunga o'xshash nomli tozalagich ilovalar bilan aloqasi yo'q
([NAMING.md](docs/NAMING.md)).

[English](README.md) · [Qanday ishlaydi](docs/ARCHITECTURE.md) · [Xavfsizlik](docs/SAFETY.md) ·
[Tasdiqlash natijalari](docs/VALIDATION.md) · [Savol-javob](docs/FAQ.md) (hujjatlar ingliz tilida)

<p align="center"><img src="docs/images/menu-uz.png" width="360" alt="iClear menyusi: Mac salomatligi 100/100, xotira me'yorida, Kuzatish rejimi"></p>

## Tasdiqlangan doira

| Tasdiqlangan (laboratoriya, bitta Mac) | Natija |
|---|---|
| Haqiqiy ilovalarni (Chrome, VS Code, TextEdit, Preview) pauza qilish va davom ettirish: har biriga 300 sikl, 100 tasi 8 GB sun'iy bosim ostida | 0 qotish, 0 pauzada qolgan, 0 hujjat o'zgarishi, 0 crash hisobot; 15.1 ms ichida yana javob beradi (p99) |
| Ilovalar pauzada (100 marta) yoki stash'da (50 marta) turganda xizmat `kill -9` bilan o'chirildi | 150/150 holatda 2 soniya ichida davom ettirildi va ko'rsatildi; p99 98 ms |
| Stash va pop, 4 ilovaning 50 sikli | oynalar 0.0 nuqta aniqlikda joyida (350/350); oldingi faol ilova 50/50 holatda qaytdi; pauzada yoki yashirin qolgan yo'q |
| Pleyer ijro etganda, qo'ng'iroq mikrofondan foydalanganda yoki Chrome yuklab olganda himoyalar | 123 ta muzlatish urinishining 123 tasi rad etildi |
| 10-300 soniyalik pauzalar: Chrome tablari, chat mijozlari | ma'lumot yo'qolmadi; Chrome va heartbeat'li chat mijozi taxminan 1.1 soniyada tiklandi; heartbeat'siz mijoz oflayn qoldi (shuning uchun chat ilovalari himoyalangan) |
| Barcha imkoniyatlar yoqilgan 60 daqiqalik sinov, Faol laboratoriya xizmati | 60 daqiqa, 0 xato: 12/12 stash/pop sikli, 6 bosim epizodi, 6/6 simulyatsiya qilingan qo'ng'iroq aniqlandi, 0 qotish |
| Xizmat yuki, 10 daqiqa, haqiqiy ilovalar, Kuzatish rejimi | protsessorning bitta yadrosidan 0.48%, 40 MB |
| `iclear selftest` (to'liq) | 13 ta tekshiruvdan 13 tasi o'tdi, o'tkazib yuborilgani yo'q |

**Tasdiqlanmagan:** haqiqiy Slack, Spotify yoki istalgan shaxsiy akkaunt (qo'lda
tekshirish ro'yxati [MANUAL_TESTS_APPS.md](docs/MANUAL_TESTS_APPS.md) da); Intel Mac'lar
(u yerda faqat CI testlari ishlaydi); macOS 13 va 14; 8 GB va undan kam xotirali Mac'lar;
batareya taxminlari (batareyadan ishlagan holda yaroqli sinovlar yo'q; maqsad rejimi
tajribaviy va o'chirilgan); 7 kunlik soak (davom etmoqda); Safari, Docker, Xcode va
virtual mashinalarni muzlatish; saqlanmagan o'zgarishlar signali (laboratoriyada hech bir ilova uni bermadi); pauzadagi pleyerga yuborilgan media tugmalari; issiqlik himoyasi. Testi yo'q hamma narsa
[TEST_MATRIX.md](docs/TEST_MATRIX.md) da sanab o'tilgan.

## Qachon yordam beradi va qachon bermaydi

**Yordam beradi:** xotira bosimi sariq yoki qizil, siz ishlatmayotgan bir nechta og'ir
ilova ochiq (brauzerlar, Electron ilovalari, dizayn vositalari, muharrirlar) va ular
fonda tez-tez uyg'onib turadi.

**Yordam bermaydi:**

- Xotira bosimi yashil. macOS buni o'zi yaxshi uddalaydi va iClear hech narsa qilmaydi.
- Xotirani siz hozir ishlayotgan ilova egallagan.
- Xotira to'xtamasligi kerak bo'lgan narsaga tegishli (build, model, virtual mashina,
  qo'ng'iroq). iClear ularni pauza qilmaydi.
- Uyg'onmasdan jim turgan ilovalar. macOS ularni baribir siqadi, muzlatilgan yoki
  muzlatilmaganidan qat'i nazar.
- Kundalik ishingiz uchun RAM shunchaki yetmaydi. Bir haftalik ma'lumot yig'ilgach,
  `iclear advise` buni aytib beradi.

## Nima qiladi

| Imkoniyat | Sukut bo'yicha | Izoh |
|---|---|---|
| Xotira bosimi ostida bo'sh fon ilovalarini pauza qilish va davom ettirish | `iclear mode active` gacha Kuzatish rejimi (faqat yozib boradi) | Butun jarayonlar daraxti, ko'rinadigan oyna yo'q, barcha tekshiruvlardan o'tgan; ilova faollashtirilganda birinchi bo'lib davom ettiriladi |
| Ish stolini yig'ib qo'yish (Stash): `iclear stash <nom>`, `iclear pop` | siz so'raganingizda | Bir nechta ilovani yashirib pauza qiladi va xuddi o'sha oynalar va oldingi faol ilova bilan qaytaradi; audio, mikrofon, quvvat tasdig'i (power assertion) yoki kamerada qo'ng'iroq qilayotgan ilovalarni hech qachon pauza qilmaydi |
| Ilova sinflari, `iclear compat <ilova>` | yoqilgan | Chat, pochta, taqvim va media ilovalari sukut bo'yicha hech qachon pauza qilinmaydi; audio ijro etayotgan yoki mikrofondan foydalanayotgan ilova, undan keyin ham 10 daqiqa davomida pauza qilinmaydi; brauzerlar ikki baravar uzoqroq kutadi |
| `iclear why`, Mac salomatligi bahosi, runaway himoyasi | yoqilgan | O'lchangan ma'lumotdan oddiy tildagi javoblar; runaway himoyasi faqat xabar beradi |
| `iclear selftest` | yoqilgan | Mac'ingizda iClear'ning o'z sinov jarayonlari bilan taxminan 2 daqiqalik tekshiruv |
| `iclear before <ilova>` | yoqilgan | "Buni ochsam xotira sariqqa o'tadimi?" Mac'ingiz tarixidan; 30 tadan kam o'lchov bo'lsa javob bermaydi |
| Beachball tahlili: `iclear beachball` | yoqilgan, Accessibility kerak | Oldingi ilova qotib qolishlarini va o'sha paytda Mac nima qilayotganini yozadi |
| Batareya taxminlari: `iclear battery` | taxminlar "taxmin" belgisi bilan ko'rsatiladi; **maqsad rejimi tajribaviy va o'chirilgan** | Tasdiqlanmagan |
| Qo'ng'iroq rejimi (Call Mode), Beachball yumshatish, issiqlik himoyasi | **o'chirilgan** | Yoqish qoidalari [RELEASE_CRITERIA.md](docs/RELEASE_CRITERIA.md) da (C8); laboratoriyada Qo'ng'iroq rejimi taymer tebranishini kamaytirdi, lekin boshqa ilovalar ishini ikki baravar kamaytirdi, Beachball yumshatish esa natijani biroz yomonlashtirdi ([VALIDATION.md](docs/VALIDATION.md)) |
| Profillar, Fokus xavfsiz rejimi, Bekor qilish, Hammasini davom ettirish, favqulodda tugmalar (menyu ilovasi ishlaganda Control-Option-Command-T), hisobot, explain | yoqilgan | 0.1 dagidek |

Har birining holati va dalillari: [SIGNATURE_FEATURES.md](docs/SIGNATURE_FEATURES.md).

## v1.1 uchun ishlab chiqilmoqda (chiqarilmagan, tasdiqlanmagan)

Bular `v1.1` tarmog'ida. Ularning laboratoriya sinovlari ([RELEASE_CRITERIA.md](docs/RELEASE_CRITERIA.md),
4-bosqich) 7 kunlik soak tugagandan keyin boshlanadi; ungacha faqat
[FEASIBILITY.md](docs/FEASIBILITY.md#11-spikes-2026-10-02) dagi dastlabki tajribalar o'lchangan.

- **Auto-Context Stash** (`iclear hook zsh|bash|fish`, `iclear context add | list |
  remove | status | pause | resume | undo | suggest`). Kichik shell hook iClear'ga
  terminalingiz qaysi papkada ekanini aytadi. Boshqa loyihada 20 soniya o'tgach, iClear
  bitta almashtirishni *taklif qiladi*: tark etilgan loyiha ilovalarini yashiradi
  (`context:<nom>` sifatida) va yangi loyiha ilovalarini qaytaradi. Ikkala loyiha
  ishlatadigan ilovalar, shuningdek pauza qilib bo'lmaydigan ilovalar (audio, mikrofon,
  qo'ng'iroq) ishlashda davom etadi; qat'iy to'siq (masalan, diskda joy yetmasligi)
  butun almashtirishni to'xtatadi. Avtomatik almashtirish har bir kontekst uchun alohida
  yoqiladi va faqat Faol rejimda ishlaydi; Kuzatish rejimi faqat "almashtirgan bo'lardi"
  deb yozadi. Loyiha ichidagi ko'chishlar, `cd ~` va `/tmp` almashtirmaydi; har bir
  almashtirishdan keyin 5 daqiqalik tanaffus bor; `iclear context undo` oxirgisini bekor
  qiladi. Almashtirish bir zumda bo'lmaydi: taxminan qaytarish (pop) qancha vaqt olsa,
  shuncha oladi (1.0 laboratoriyasida p50 1.34 s). Cheklovlar: faqat terminallarni
  ko'radi, shuning uchun faqat IDE ichida qilingan ish ko'rinmaydi; turli loyihalardagi
  terminallar kutish vaqti ichida xabar bersa, joriy kontekst o'zgarmaydi; fish, tmux
  va boshqa multiplekserlar sinalmagan. Dastlabki tajribada hook har bir papka
  almashishiga taxminan 1-2 ms qo'shdi (zsh va bash).
- **Xotira o'sishi tendensiyasi** (`iclear leaks`; menyuda: O'sish). Har bir ilovaning
  xotira hajmini daqiqasiga bir marta o'lchaydi va ilova ishlatilmayotganda (oxirgi 10
  daqiqada oldingi planda bo'lmagan) barqaror o'sishni kamida 2 soat va 12 o'lchovdan
  keyin xabar qiladi: "soatiga X MB o'sish (oraliq), shu tezlikda HH:MM atrofida Y GB",
  ishonch darajasi bilan. Bu tendensiya, xotira oqishi tashxisi emas: keshlar va loglar
  ham o'sadi. Bir martalik sakrash (hujjat ochilgan) va to'lib-bo'shaydigan keshlar
  xabar qilinmaydi. Xotira bosimi bilan faqat tizim prognozi orqali bog'lanadi va u
  "taxmin" deb belgilanadi. Tarix xotirada saqlanadi va daemon qayta ishga tushganda
  qaytadan boshlanadi. Bildirishnomalar o'chirilgan va yolg'on signal tekshiruvi (L5)
  o'tmaguncha o'chiq qoladi. `iclear leaks quit <ilova>` avval nima bo'lishini
  ko'rsatadi; `--yes` bilan ilovadan o'zining Quit buyrug'i orqali yopilishni so'raydi
  va uni majburan yopmaydi. "Tozalash" tugmasi yo'q: macOS'da boshqa ilovani xotira
  bo'shatishga yoki axlat yig'ishga majburlash usuli yo'q.

- **Panic Brake** (`iclear brake observe | on | off | status | report | resume | quit`).
  Alohida kichik kuzatuvchi (`icbrake`, o'z LaunchAgent'i, AppKit'siz, aniq vaqtli
  oqim) har 250 ms da xotira bosimi, svopdan qaytarishlar, siqilgan xotirani ochish,
  sahifa yuklanishlari, navbat va o'z taymeri kechikishini o'qiydi. Mac xotira tufayli
  qotib qolsa (xotira belgisi va javob berish muammosi birga, yoki kritik bosim), u sizning
  jarayon daraxtlaringizni xotira o'sishi, sahifa yuklanishi va protsessor bo'yicha
  saralaydi va eng yuqorisini pauza qiladi (avval jurnalga yozib); qotish o'tsa, uni
  pauzada qoldiradi, aks holda davom ettirib keyingisini sinaydi (3 tagacha), 10 s da
  to'xtab xabar beradi. Oldingi plandagi ilova faqat 10 s dan keyin va faqat eng
  yuqorida bo'lsa nomzod bo'ladi. U **kuzatish** rejimida boshlanadi: faqat "pauza
  qilgan bo'lardim" deb yozadi; pauzalar bosim normal bo'lganda, ilovani ochganingizda
  yoki 4 soatda tugaydi. Majburan o'chirmaydi.
  Ixtiyoriy, har bir ilova uchun alohida va standart holatda o'chiq: `brake.autoQuitApps`
  ro'yxatidagi ilova `brake.autoQuitSeconds` (30 s) davomida tasdiqlangan sababchi bo'lib
  qolsa, undan o'zining Quit buyrug'i bilan yopilish so'raladi (saqlash va tiklash jarayoni
  ishlaydi); ilova saqlanmagan ish borligini bildirsa (bu signal mavjud bo'lsa), bu qadam
  o'tkazib yuboriladi, so'rovni e'tiborsiz qoldirgan ilova esa yana pauza qilinadi.
  `iclear brake status` har bir pauzadagi ilova bilan nima bo'lishini ko'rsatadi. 1.0
  laboratoriyasida hech bir ilova saqlanmagan o'zgarishlar signalini bermadi, shuning
  uchun ishonchli signali yo'q ilova yopilganda saqlanmagan ishni yo'qotishi mumkin: faqat
  avtomatik saqlaydigan va oynalarini tiklaydigan ilovalarni yoqing. Sahifa almashtirmaydigan og'ir ish (kompilyatsiya,
  nusxalash, eksport) uni ishga tushirmasligi kerak; bu oldindan belgilangan sinov,
  hali o'tkazilmagan.
- **Black Box** (`iclear blackbox`). Oxirgi ~5 daqiqa, 2 s oralig'ida (bosim, svop,
  sahifa yuklanishlari, harorat va quvvat holati, eng shubhali ilovalar nomi), faqat Mac
  sog'lom bo'lmaganda yoziladi. To'g'ri o'chirilmasdan qayta ishga tushgandan keyin menyu
  va `iclear blackbox` o'sha vaqt chizig'ini ko'rsatadi. Oxirgi bir necha soniya
  yo'qolishi mumkin. macOS'ning "Previous shutdown cause" yozuvi faqat foydalanuvchi uni
  o'qiy olsa ko'rsatiladi; sinov Mac'ida o'qib bo'lmaydi.

- **Canary probe** (`iclear probe <ilova> [--cycles N]`). Sizning roziligingiz bilan
  (so'rovda), faqat ilova yashirin, oldingi planda emas, barcha himoyalardan o'tgan va Mac
  zaryadda bo'lganda: bir necha qisqa jurnalli pauza (standart 5 ta, har biri ko'pi bilan
  5 s); har bir davom ettirishdan keyin ilova tirikligini, javob berishini (Accessibility
  bilan, oynasi bor ilovalar uchun) va ulanishlari saqlanganini tekshiradi, yangi
  nosozlik hisobotlarini qidiradi. Muvaffaqiyatsizlik ilovani karantinga oladi;
  `probe.requirePassed` (o'chiq) avtomatik pauzalarni faqat sinovdan o'tgan ilovalarga
  cheklaydi. Ilovani oldinga chiqarsangiz sinov to'xtaydi va ilova davom etadi.
- **Capacity Report** (`iclear capacity [--json]`, menyu qatori). Har bir pauza uchun
  60 s dan keyin bo'sh xotiraning o'lchangan o'zgarishi, pauzadagi hajm, vaqt va
  afsuslar; ogohlantirishgacha qolgan zaxira taxmini (oraliq bilan); svop va uning
  24 soatlik o'zgarishi; pauza bo'lmasa "xabar qiladigan narsa yo'q". Nimani o'zgartira
  oladi va nimani yo'q: [CAPACITY.md](docs/CAPACITY.md). Laboratoriya natijasi hali e'lon
  qilinmagan.
- **Wake-on-Data** (`wakeOnData`, **o'chiq**, faqat tanlangan chat yoki brauzer ilovasi
  uchun). Bunday ilova pauzada bo'lganda iClear har 250 ms da uning soketlaridagi qabul
  navbatini tekshiradi (libproc, root kerak emas); ma'lumot kutayotgan bo'lsa ilovani
  davom ettiradi (`WAKE_DATA_RX`) va ma'lumot to'xtagach 5 s dan keyin yana pauza qiladi
  (`REFREEZE_QUIET`), agar qo'ng'iroq, audio yoki boshqa himoya to'sqinlik qilmasa. Vaqtning
  20% dan ko'pida davom ettirilgan ilova ishlab turaveradi. Qamrab olinmaydi: Apple push
  bildirishnomalari, trafigi boshqa jarayon orqali o'tadigan ilovalar (VPN, proksi, tarmoq
  kengaytmasi; qo'llab-quvvatlanmaydi deb belgilanadi), tizim ko'rmaydigan QUIC. Hali
  o'lchanmagan.
- **Thrash Guard** (`thrash.enabled`, **o'chiq**). Fon ilovalari tez-tez uyg'onib sovuq
  xotiraga tegsa, Mac doimiy sahifa yuklaydi va oldingi plandagi ilova qotadi. Bunday
  holatda (sahifa yuklanish bo'roni va ogohlantiruvchi bosim yoki qotish, ketma-ket
  o'lchovlarda) o'z sahifa yuklanishi eng yuqori bo'lgan fon ilovalari odatdagi jurnalli
  yo'l bilan pauza qilinadi (`THRASH_PAGEIN`); "protsessor bo'yicha bo'sh" shartidan
  boshqa barcha himoyalar amal qiladi. Oldindan belgilangan laboratoriya mezonlari (T1-T4)
  o'tmaguncha o'chiq qoladi; hali o'lchanmagan.

### Panic Brake nimani tuzata olmaydi

U faqat sizning foydalanuvchi ilovalaringiz va jarayonlaringiz bilan ishlaydi. Yadro,
GPU/drayver yoki WindowServer qotishlari, apparat nosozliklari va root jarayonlari
(Spotlight `mds`, Time Machine `backupd`, `kernel_task`) uning qo'lidan kelmaydi: bunda u
faqat ko'rganini yozib qo'yadi. To'liq qotib qolgan Mac'ni hech qanday ilova qutqara
olmaydi. Mac'ni qanchalik tez tiklashi hali o'lchanmagan; mezonlar va raqamlar
[RELEASE_CRITERIA_v1.1.md](docs/RELEASE_CRITERIA_v1.1.md) da.

Ikkalasi uchun mavjud ishlar ([NOVELTY.md](docs/NOVELTY.md#v11-re-audit-2026-10-02),
2026-10-02 da qidirilgan): ish muhiti vositalari ilovalar guruhini tugma bilan ochadi va
yopadi (Bunch, Commute, Ikuna, ShiftPlus), autohide esa ishlatilmayotgan ilovalarni
yashiradi; xotira o'sishi tendensiyasining statistikasi (Mann-Kendall va Sen qiyaligi)
ma'lum usul, boshqa Mac vositalari ham o'sayotgan ilovalarni belgilaydi (RamRadar, Memory
Monitor, Mac Performance Monitor). Panic Brake uchun: earlyoom Linux'da eng katta jarayonni
o'chirib xuddi shu vazifani bajaradi; memory_guard.py macOS'da siz ko'rsatgan jarayon
daraxtlarining yaratuvchilarini pauza qiladi, keyin ishchilarni o'chiradi; turnstile
bosim ostida o'z vazifalarini o'chirishdan oldin pauza qiladi.

## Ma'lum yon ta'sirlar

Pauza ilovaga nima qilishi simulyatorlar va mahalliy sahifalardagi Chrome bilan
o'lchangan ([VALIDATION.md](docs/VALIDATION.md), "Side effects"). Yuqoridagi sukut
sozlamalari shular sababli bor; `iclear compat <ilova>` ularni bitta ilova uchun
ko'rsatadi.

- **Chat, pochta va taqvim ilovalari** siz o'zingiz yoqmaguningizcha hech qachon pauza
  qilinmaydi. Pauzadagi ilova hech narsa qabul qilmaydi, u javob bermay qo'ygach esa
  server ulanishni uzadi (laboratoriya serveri 30 soniyadan keyin). O'z "yurak urishi"
  (heartbeat) tekshiruvi bor simulyatsiya qilingan mijoz davom ettirilgandan keyin
  taxminan 1.1 soniyada qayta ulandi va o'tkazib yuborilgan barcha xabarlarni kechikib
  (300 soniyalik pauzadan keyin 296 soniyagacha) oldi, birortasi ham yo'qolmadi. Uzilishni
  faqat soketdan bilishga tayanadigan mijoz 60 soniya va undan uzun har bir pauzadan
  keyin **oflayn qolib ketdi**. Ixtiyoriy "uyg'onish oynalari"
  (`packaging/rules/chat-wake-windows.json`) laboratoriyada eng katta kechikishni 296
  soniyadan 36 soniyaga qisqartirdi, evaziga ilova tez-tez uyg'onadi; qo'ng'iroq paytida
  ular qayta muzlatilmaydi.
- **Media pleyerlar** sukut bo'yicha hech qachon pauza qilinmaydi: ijro paytida ham,
  undan keyingi 10 daqiqada ham. Pauzadagi pleyer media tugmalari yoki Boshqaruv
  markaziga javob bera olmaydi; bunda macOS nima qilishi qo'lda tekshiriladi.
- **Brauzerlar** faqat butun daraxt sifatida va hech bir tab audio ijro etmayotgan,
  mikrofon yoki kameradan foydalanmayotgan, yuklab olmayotgan, fayl yozmayotgan va quvvat
  tasdig'ini ushlab turmagan paytda pauza qilinadi (WebRTC ulanishi ochiq turganda Chrome
  shunday tasdiqni ushlab turadi). Laboratoriyada bu himoyalar sinov Chrome'ini pauza
  qilishga bo'lgan har bir urinishni rad etdi. Laboratoriya uni baribir 10-300 soniyaga
  pauza qilganda, har bir sahifa davom ettirilgandan keyin 0.03 soniya ichida javob berdi,
  formadagi ma'lumot va taymerlar saqlanib qoldi, WebSocket sahifalari 1.1 soniya ichida
  qayta ulandi, WebRTC ma'lumot kanali va service worker ishlashda davom etdi. Chrome'ning
  o'zi ham Energy Saver yoqilganda yashirin, protsessorni ko'p ishlatadigan tablarni
  muzlatadi (Page Lifecycle "frozen" holati, Chrome 133 va undan keyingi) va Memory Saver
  rejimida faol bo'lmagan tablarni xotiradan chiqaradi, ularga qaytganingizda qayta
  yuklanadi.
- **"Not Responding" (javob bermayapti)**: pauza paytida ilova Force Quit, Activity Monitor
  yoki Dock menyusida "Not Responding" bo'lib ko'rinishi mumkin. Pauzadagi jarayon shunday
  ko'rinadi; uni faollashtirsangiz davom etadi. Uni majburan yopmang.
- **Soat va taymerlar**: pauza paytida vaqt o'tishda davom etadi. Davom ettirilgandan
  keyin takrorlanuvchi taymer bir marta ishlaydi (bir yo'la ko'p marta emas), pauzani qamrab
  olgan kutish muddatlari esa darhol tugaydi.
- **Uzilgan ulanishlar**: serverlar o'zlariga javob bermay qo'ygan ulanishlarni yopadi;
  qayta tiklanish ilovaning o'ziga bog'liq (ko'pchilik chat ilovalari qayta ulanadi,
  yuqoriga qarang). Yuklab olishlar himoyalangan: 200 MB yuklab olish to'g'ri nazorat
  yig'indisi (checksum) bilan tugadi, pauza qilishga bo'lgan har bir urinish esa rad etildi.
- Pauza paytiga to'g'ri kelgan **bildirishnomalar** kechikib chiqadi yoki umuman chiqmaydi
  (o'lchanmagan).

## O'lchangan natijalar

| Nima (bitta Mac, laboratoriya, tafsilotlar [VALIDATION.md](docs/VALIDATION.md) da) | Natija |
|---|---|
| Davom ettirishdan javob berishgacha (asosiy oqim Accessibility so'roviga javob beradi), haqiqiy ilovalarning 1 200 sikli | p50 2.5-3.6 ms, p99 ≤ 15.1 ms, maksimum 47.3 ms |
| "Sariq" (warning) bosimda muzlatilgan haqiqiy ilovalar qaytargan xotira (birinchi epizod) | Chrome 1 203 → 803 MB (−33%), VS Code 1 709 → 1 046 MB (−39%), Preview 130 → 84 MB (−35%); "me'yoriy" bosimda macOS kam qaytaradi (mediana −1% dan −4% gacha) |
| Xizmat `kill -9` bilan o'chirilgandan keyin davom ettirish (watchdog), 150 sinov | p50 76-85 ms, p99 98 ms |
| Pop: barcha yashirilgan ilovalar ko'ringuncha, 50 sikl | p50 1.34 s, p99 1.36 s (pop oldingi faol ilova 0.5 soniya oldinda turishini kutadi) |
| 24 ta raqobatchi jarayon ostida qo'ng'iroq taymeri tebranishi, Qo'ng'iroq rejimi o'chiq / yoqiq | p99 0.32 / 0.08 ms (Qo'ng'iroq rejimi o'chiq qoladi: u boshqa ilovalar ishini ikki baravar kamaytiradi) |
| Xizmat, bo'sh holatda, Kuzatish rejimi, haqiqiy ilovalar, 10 daqiqa | protsessorning bitta yadrosidan 0.48%, 40 MB |

Eski sintetik o'lchovlar: [BENCHMARKS.md](docs/BENCHMARKS.md).

## Ruxsatlar

| Ruxsat | Majburiymi? | Nima uchun | Rad etilsa |
|---|---|---|---|
| hech qanday | | pauza, davom ettirish, stash, `why`, salomatlik bahosi, himoyalar, qo'ng'iroqni aniqlash (iClear mikrofon yoki kamera *ishlatilayotganini* biladi, xolos; ovoz yoki tasvirni hech qachon olmaydi) | hammasi ishlaydi |
| Maxsus imkoniyatlar (Accessibility) | ixtiyoriy | davom ettirilgan ilova javob berishini tekshirish; kechikish; qotib qolish tahlili; pop'dan keyin aynan oldingi ilovani oldinga chiqarish. Stash shu yo'l bilan saqlanmagan o'zgarishlarni ham so'raydi, lekin laboratoriyada hech bir ilova ularni bildirmadi (har biri "noma'lum" bo'ldi), shuning uchun bu tekshiruv tasdiqlanmagan | davom ettirishdan keyingi qotish aniqlanmaydi; kechikish va qotishlar "o'lchanmagan" |
| Kiritishni kuzatish (Input Monitoring) | ixtiyoriy | tajribaviy oldindan davom ettirish (o'chirilgan) | hech narsa o'zgarmaydi |
| Mikrofon | faqat `iclear selftest` uchun | uning qo'ng'iroq tekshiruvi iClear'ning o'z sinov vositasini ishga tushiradi, u bir necha soniya yozib, darhol tashlab yuboradi | o'sha tekshiruv o'tkazib yuboriladi |
| Ekranni yozib olish, Kamera | ishlatilmaydi | | |

Root kerak emas, yadro kengaytmasi yo'q, SIP o'zgartirilmaydi, tarmoqqa ulanmaydi,
telemetriya yo'q.

## O'rnatish

macOS 13 va undan yangilari, Apple Silicon va Intel uchun qurilgan (universal ikkilik fayl).

[Oxirgi relizni](https://github.com/urrra39/iClear/releases) **yuklab oling**:
`iClear-<versiya>.zip` (menyu ilovasi; buyruq qatori vositalari
`iClear.app/Contents/Helpers` ichida) yoki `iclear-<versiya>-macos.tar.gz` (faqat buyruq
qatori vositalari). Tekshiring:

```sh
shasum -a 256 -c SHA256SUMS.txt --ignore-missing
```

Buildlar ad-hoc imzolangan, notarizatsiyadan o'tmagan, shuning uchun Gatekeeper birinchi
ishga tushirishni to'xtatadi. macOS 15 va undan keyingisida: iClear.app ni bir marta oching,
keyin System Settings > Privacy & Security > Open Anyway (Apple o'ng tugma yo'lini macOS 15
da olib tashlagan). macOS 13 va 14 da: iClear.app ni o'ng tugma bilan bosing, Open ni
tanlang va tasdiqlang. Buyruq qatori vositalari: `xattr -dr com.apple.quarantine
iclear-<versiya>`, keyin uning ichida `./iclear install`.

**Manba koddan:**

```sh
git clone https://github.com/urrra39/iClear.git && cd iClear
scripts/build-release.sh           # universal ikkilik fayllar, dist/iClear.app
cp -R dist/iClear.app /Applications/
```

Homebrew tap rejalashtirilgan, lekin hali chiqarilmagan; shablonlar
[`packaging/homebrew/`](packaging/homebrew/) da.

## Tez boshlash (60 soniya)

```sh
iclear selftest --quick # 12 soniyada pauza va davom ettirish shu Mac'da ishlashini tekshiradi
iclear install          # foydalanuvchi xizmatini Kuzatish rejimida ishga tushiradi
iclear status           # u nimani ko'rmoqda va nima qilgan bo'lardi
iclear why              # Mac nega hozir sekin?
iclear compat Chrome    # pauza ilovaga nima qilishi
# ...Mac'ingizdan bir kun foydalaning, keyin:
iclear stats --days 1   # u nima qilgan bo'lardi va taxminiy afsus darajasi
iclear mode active      # unga amal qilishga ruxsat bering
```

Ilova bilan: iClear ni Applications dan oching; "iClear'ni ishga tushirish" xizmatni
o'rnatadi. Favqulodda holat: **Control-Option-Command-T** yoki `iclear thaw --all`
hammasini davom ettiradi.

## Xavfsizlik modeli

Har bir pauzadan oldin muzlatish jurnali yoziladi, va xizmat ishdan chiqsa (hatto
`kill -9` bilan ham), alohida kuzatuvchi (watchdog) jarayon hammasini davom ettiradi
(laboratoriya: 100/100 tiklanish, p99 83 ms). Har bir signal oldidan PID, boshlanish
vaqti va egasi qayta tekshiriladi. Himoyalangan to'plamni (tizim, terminallar, AI
dasturlash agentlari, parol menejerlari, sinxronlash, VPN, kiritish va maxsus imkoniyat
vositalari) hech qanday qoida bilan pauza qilib bo'lmaydi. Daraxtlar "hammasi yoki hech
biri" tamoyili bilan pauza qilinadi. Pauza vaqti (4 soat) va umumiy hajmi (RAM ning 50%)
cheklangan. Ustuvorlik va yashirish o'zgarishlari jurnalga yoziladi va aynan qaytariladi.
Stash xizmatdan uzoq yashamaydi. Qo'ng'iroq rejimi, uni o'zingiz yoqsangiz, qo'ng'iroq
paytida harakat qiladigan yagona narsa, va qo'ng'iroqning o'ziga hech qachon tegmaydi
([SAFETY.md](docs/SAFETY.md)).

## Boshqalar bilan taqqoslash

Bu loyihalar o'xshash muammolarni hal qiladi va ularning bir nechtasi buni ilgariroq
qilgan. Ularning README fayllari va sahifalari o'qib chiqildi (har bir qator
2026-10-03 da qayta o'qildi):

| Loyiha | Yondashuv | iClear dan farqi |
|---|---|---|
| [ForceNap](https://github.com/omikun/ForceNap) | Siz tanlagan ilovalarni fokusdan chiqqanda to'xtatadi, fokusga qaytganda davom ettiradi | Oddiy va to'g'ridan-to'g'ri. U tanlangan ilovalarni xotira bosimidan qat'i nazar to'xtatadi; iClear faqat bosim ostida harakat qiladi va ilovalarni o'zi tanlaydi |
| [Auto Pause Mac Apps](https://github.com/fazalrshah/auto-pause-mac-apps) | Ilovalarni pauza qilib RAM ni qaytarish uchun menyu ilovasi, holatni saqlab yopadigan "Deep Sleep" rejimi bilan | Qo'lda boshqarish qulay va iClear da yo'q holatni saqlab yopish rejimi bor. iClear avtomatik, bosimga asoslangan va himoyalar bilan tekshiriladi |
| [caproom](https://github.com/intelogroup/caproom) | Buyruqlar uchun xotira chegarasi; bo'sh jarayon daraxtlarini SIGSTOP bilan "to'xtatib qo'yadi", chegaradan oshsa o'chiradi | Terminal ishlari va agentlar uchun qat'iy chegaralar bilan qurilgan. iClear GUI ilovalarni nishonga oladi va hech qachon o'chirmaydi |
| [ProcessX](https://github.com/avantigroupai/ProcessX) | Jarayon/ustuvorlik monitori; protsessorni to'xtatib-davom ettirish orqali cheklaydi | Protsessor va ustuvorlikka qaratilgan. iClear xotira bosimiga qaratilgan |
| [GreenRAM](https://github.com/lwj1994/greenram) | RAM/svop chegarasidan oshganda uzoq bo'sh turgan fon ilovalarini majburan yopadi | Yopish barcha xotirani bo'shatadi, lekin holat yo'qoladi. iClear pauza qiladi va holatni saqlaydi |
| [Canaryd](https://github.com/ThaddeusJiang/canaryd) | To'xtab qolgan xizmatlar, Simulator, qizish va bo'sh xotira uchun kuzatuvchi; bo'sh og'ir ilovalardan yopilishni so'raydi | Dasturchi kompyuteri uchun kengroq kuzatuvchi. iClear yopish o'rniga pauza qiladi |
| [MemoryShield](https://github.com/MaatheusGois/MemoryShield) | Har bir jarayon xotira tarixi; chegaradan oshganda avtomatik o'chira oladi | Tarix va ogohlantirishlar u yerda ham bor. iClear o'chirmaydi |
| [mac-memory-guard](https://github.com/TomGranot/mac-memory-guard) | Xotira tufayli qotishdan oldin ogohlantiradi va ilovalarni birma-bir yopishga imkon beradi | Avval ogohlantiradi, qarorni inson qiladi. iClear o'zi harakat qiladi |
| [WattMate](https://wattmateapp.com/) | Ilovalar quvvatini batareya daqiqalariga aylantiradi, oldin/keyin o'lchovi bilan | Batareya daqiqalari va "nima qaytardi" o'lchovi u yerda allaqachon bor; iClear'ning batareya taxminlari yangi emas va tasdiqlanmagan |
| [AppHalt](https://apphalt.app/) ([README](https://github.com/Gabrielnion/AppHalt)) | Siz tanlagan ilovalarni menyu panelidan pauza qilish va davom ettirish, oynalar va hujjatlar saqlanadi; pullik Pro versiyada bo'sh turgandan keyin avtomatik pauza va "hech qachon pauza qilinmasin" ro'yxati bor | Qo'lda boshqarish va ilovalar bo'yicha qoidalar qulay. iClear xotira bosimi va har bir ilova himoyalari asosida qaror qiladi, Kuzatish rejimida boshlanadi |
| [MacFreeze](https://github.com/exadeci/mac_freeze) | Glob naqshlariga mos ilovalarni har biri uchun belgilangan bo'sh vaqtdan keyin muzlatadi (SIGSTOP/SIGCONT), o'zi yopilganda hammasini davom ettiradi | Oddiy va sozlanadigan, xotira bosimidan qat'i nazar muzlatadi. iClear bosim ostida harakat qiladi, avval audio, qo'ng'iroq, ulanish va yozishni tekshiradi, har bir pauzani jurnalga yozadi |
| [wintertime](https://github.com/actuallymentor/wintertime-mac-background-freezer) | Ro'yxatidagi ilovalarni fokusdan chiqqanda muzlatadi (`pkill` orqali), batareyani tejash uchun; hammasini davom ettiradigan favqulodda tugmasi bor; macOS 10.13 da sinalgan | Fokusga va batareyaga qaratilgan. iClear bosimga asoslanadi va o'zi ishdan chiqsa ham jurnaldan tiklaydi |
| [ShiftPlus](https://shiftplus.app/blog/shift-mac/) | Tugma bilan ish to'plamini almashtiradi: to'plamga kirmagan ilovalarni yopadi yoki yashiradi, keraklilarini brauzer profillari, Spaces va terminal o'zgaruvchilari bilan ochadi | Ish to'plamini ilovalarni yopib-ochib qayta quradi. iClear stash ilovalarni joyida yashirib pauza qiladi va holatini saqlaydi; brauzer profillari yoki Spaces'ni boshqarmaydi |
| [ContextResume](https://github.com/yigitbozyaka/ContextResume) | Har bir git branch uchun eslatma (git holati, oxirgi xato bergan buyruq, niyatingiz), branch almashganda shell prompt hook orqali ko'rsatadi | Nima qilayotganingizni eslab qoladi, qaysi ilovalar ochiq bo'lganini emas; ilovalarni pauza qilmaydi va boshqarmaydi |
| [direnv](https://direnv.net/) | Shell hook orqali har bir katalog uchun muhit o'zgaruvchilarini yuklaydi va olib tashlaydi | Yondosh, boshqa muammo: ilovalar emas, shell muhiti |
| [SceneShift](https://tandukuda.github.io/SceneShift/) | Faqat Windows: ilovalar to'plamini o'chiradigan, to'xtatadigan, davom ettiradigan yoki qayta ochadigan terminal vositasi, bekor qilish bilan | Windows'dagi o'xshash to'xtatish-tiklash g'oyasi; iClear macOS uchun va xotira bosimiga qarab ishlaydi |
| [earlyoom](https://github.com/rfjakob/earlyoom) (Linux) | Bo'sh xotira va svop 10% dan tushganda eng katta jarayonni o'chiradi (SIGTERM, keyin SIGKILL); mlockall, taxminan 2 MiB | Panic Brake macOS'da shu g'oyaga amal qiladi, lekin o'chirish o'rniga pauza qiladi va jurnal yuritadi |
| [memory_guard.py](https://gist.github.com/jlevy/5b43e0d44166b9c7fe8157ee938cb0d5) | Siz ko'rsatgan jarayon daraxtlari uchun macOS kuzatuvchisi: kuzatish, mashq, faqat pauza va to'liq rejimlar; yaratuvchilarni pauza qiladi, keyin ishchilarni o'chiradi | Usuli yaqin. Panic Brake barcha jarayon daraxtlaringizni saralaydi, hech narsani o'chirmaydi va har bir pauzani qotishga qarab tekshiradi |
| [turnstile](https://github.com/mcclowes/turnstile) | Vazifalar ishga tushirgichi: xotira chegarasidan oshgan vazifa bosim ostida pauza qilinadi, bosim 15 s davom etsagina o'chiriladi | Faqat o'z vazifalari bilan ishlaydi |
| [Bunch](https://bunchapp.co/) | Ilovalarni ochadigan, yopadigan va skript ishga tushiradigan matnli "Bunch"lar, menyudan | Qo'lda ochadi va yopadi; Auto-Context terminalingizdagi loyiha o'zgarganda ilovalar guruhini pauza qiladi |
| [Commute](https://apps.apple.com/app/id1564572231) | Ilovalar to'plamini ochib, boshqalarini yopadigan profillar, tugma bilan | Bunch bilan bir xil farq |
| [Ikuna](https://www.brnsft.com/blog/best-mac-apps-for-project-switching-save-browser-tabs-apps-and-files-instantly-in-2026) | Joriy ish muhitini yopib, boshqasini tiklaydi (ilovalar, tablar, oyna joylari), tugma bilan; nashriyotchi aytishicha "uch soniyadan kam" | Yopib qayta ochadi; iClear joyida pauza qiladi |
| [RamRadar](https://github.com/gemscng/RamRadar) | Oldingi tekshiruvdan beri kamida 1 GB va 50% o'sgan dasturlarni belgilaydi va so'rov bilan to'xtatadi | Ikki o'lchovli chegara va yopish; xotira o'sishi tendensiyasi bo'sh holatdagi o'lchovlar bo'yicha barqaror tendensiyadan foydalanadi va majburan yopmaydi |
| [Mac Performance Monitor](https://github.com/Zesty0wl/mac-performance-monitor) | Menyu panelidan protsessor, xotira, GPU, tarmoq va batareyani yozadi; o'sish tekshiruvlari tashxis emas, kuzatuv sifatida | Faqat kuzatish |
| Windows [ControlChannelTrigger](https://learn.microsoft.com/en-us/uwp/api/Windows.Networking.Sockets.ControlChannelTrigger?view=winrt-22621) | To'xtatilgan Windows ilovasiga TCP ulanishni saqlash va ma'lumot kelganda uyg'onish imkonini beradi | Wake-on-Data g'oyasi shundan; macOS'da iClear pauzadagi ilovaning qabul navbatini tashqaridan, ilovaning yordamisiz kuzatadi |
| [amphetamine](https://github.com/GriffinCanCode/amphetamine) (Rust crate) | Apple Silicon buyruq qatori: ilovalardan yopilishni so'raydi (majburan o'chirmaydi), raqib jarayonlarni `nice` bilan faqat aniq tiklay olsagina pasaytiradi, svop nega qolishini tushuntiradi, ikki papkadagi eski keshlarni o'chiradi | Pauza o'rniga yopadi va kesh o'chiradi; iClear pauza qiladi, holatni saqlaydi va fayl o'chirmaydi. Ikkalasi ham ustuvorlik o'zgarishini aynan qaytaradi |

2026-10-03 holatiga ko'ra, biz bosim uchun ETA prognozi, afsusni hisobga oluvchi
muzlatish, pauzadan oldingi ulanish/yozish himoyalari, davom ettirishdan keyingi
karantin yoki iz qayta ijrosini bu loyihalarda ham, GitHub va veb qidiruvlarimizda ham
topmadik ([NOVELTY.md](docs/NOVELTY.md)). Chrome'ning o'zi Energy Saver rejimida yashirin,
ovozsiz va protsessorni ko'p ishlatadigan tablarni muzlatadi (Chrome 133 dan) va Memory
Saver rejimida tablarni o'chiradi, brauzer ichida. Dalil yo'qligi isbot emas: topilmagani
mavjud emasligini anglatmaydi.

## Qayerda sinalgan

Yuqoridagi laboratoriya natijalari: bitta Mac (Apple M3 Pro, 18 GB, macOS 27.0.1).
Avtomatik testlar (188 ta test) GitHub'ning macOS 15 (Apple Silicon va Intel)
va macOS 26 runnerlarida ham o'tadi. iClear chegaralarini RAM hajmi, disk turi va
batareyaga moslaydi, lekin "har qanday MacBook'ga moslashadi" degani "har bir MacBook'da
sinalgan" degani emas. `iclear doctor --report` ni ishga tushiring va Mac'ingizni
[COMPATIBILITY.md](docs/COMPATIBILITY.md) ga qo'shing.

## iClean dan o'tish

iClear bu iClean ning yangi nomi. Agar iClean 0.1.0 o'rnatilgan bo'lsa, `iclear install`
(yoki `iclear migrate`) avval iClean pauza qilgan hamma narsani davom ettiradi (agar
uning xizmati ishlayotgan bo'lsa u orqali, keyin muzlatish jurnalini qayta o'qib), faqat
shundan keyin eski LaunchAgent ni to'xtatadi va o'chirib qo'yadi hamda sozlamalar, holat
va izlarni nusxalaydi. Agar eski jurnaldagi jarayon hali ham pauzada bo'lsa, hech narsani
o'zgartirmasdan to'xtaydi. Eski fayllar `iclear migrate --remove-old` ni ishga
tushirmaguningizcha joyida qoladi. `iclear migrate --dry-run` avval rejani ko'rsatadi.

## O'chirib tashlash

```sh
iclear uninstall --purge   # xizmatni to'xtatadi (hammasini davom ettiradi), LaunchAgent ni
                           # olib tashlaydi va ~/Library/Application Support/iClear ni o'chiradi
rm -rf /Applications/iClear.app
```

## Batafsil

[Arxitektura](docs/ARCHITECTURE.md) · [Xavfsizlik](docs/SAFETY.md) ·
[Tasdiqlash natijalari](docs/VALIDATION.md) · [Reliz mezonlari](docs/RELEASE_CRITERIA.md) ·
[Testlar xaritasi](docs/TEST_MATRIX.md) · [Imkoniyatlarni o'rganish](docs/FEASIBILITY.md) ·
[Qarorlar](docs/DECISIONS.md) · [Sifat](docs/QUALITY.md) · [Hissa qo'shish](CONTRIBUTING.md) ·
[Xavfsizlik siyosati](SECURITY.md) · [O'zgarishlar](CHANGELOG.md)

MIT litsenziyasi. Apple Inc. bilan bog'liq emas. macOS va MacBook Apple Inc.ning
savdo belgilaridir. iClear shunga o'xshash nomli kesh va disk tozalagichlar bilan
bog'liq emas ([NAMING.md](docs/NAMING.md)).
