# Протокол StekTrustPlugin `/TRUST/*` — реверс-спецификация

Снято с живого трафика (tcpdump lo0:18080) + анализа бинаря 2026-07-16.
Цель — нативная **arm64**-замена демона (StekTrustPlugin = x86_64 Lazarus, обречён Rosetta).
`<THUMB>` = SHA-1 отпечаток сертификата (40 hex, uppercase). Перс. данные вырезаны.

## Транспорт
- HTTP/1.1 сервер на `http://127.0.0.1:18080`, `Server: TRUST`.
- CORS всегда открыт: `Access-Control-Allow-Origin: *`, `Allow-Methods: POST, GET, OPTIONS`,
  `Allow-Headers: Origin, X-Requested-With, Content-Type, Accept`, `Max-Age: 86400`.
- Запросы шлёт страница moedelo.org (в Safari — через наше расширение,
  `Origin: safari-web-extension://…`; в Chrome — напрямую). Тело POST идёт как `Content-Type: text/plain`.
- Ответ: `Content-Type: application/json; charset=utf-8` (UTF-8, кириллица в DN — как есть).

## Единый конверт ответа
```json
{ "Status": true|false, "Data": <payload|null>, "Errors": [ "текст" ] }
```
`Status:false` + текст в `Errors` при ошибке (напр. `"Не указан SN (или Thumbprint) сертификата"`).

## Эндпоинты

### 1. `GET /TRUST/GetVer?`
Версия плагина. → `Data: "2.7.0.4"` (строка). Наша замена может отдавать свой номер.

### 2. `GET /TRUST/TRYUSEPLUGIN_SYNC?`
Пинг «плагин жив». → `Data: null`, `Status:true`.

### 3. `GET /TRUST/ENUMCERTS_SYNC?`
Список сертификатов из хранилища КриптоПро (личные, с приватным ключом). → `Data`: массив
```json
{ "Serial":"<hex>", "Thumbprint":"<THUMB>",
  "Subject":"<полный DN>", "SubjectName":"<CN>",
  "Issuer":"<DN УЦ>", "ValidFrom":"YYYY-MM-DD", "ValidFor":"YYYY-MM-DD" }
```
Источник данных = `certmgr -list` / CryptoAPI `CertEnumCertificatesInStore` (store "My").

### 4. `GET /TRUST/GetCertBody?CertThumb=<THUMB>`
⚠️ Имя параметра именно **`CertThumb`** (не Thumbprint!). → `Data`: base64(DER сертификата).
CryptoAPI: найти по SHA-1 (`CertFindCertificateInStore CERT_FIND_HASH`), вернуть `pCertContext->pbCertEncoded`.

### 5. `POST /TRUST/CheckCertAndClue`
Тело = **base64(DER сертификата)** (`text/plain`). Проверка валидности/цепочки.
→ `Data: null`, `Status:true` если ок. (Chain build + policy verify через CryptoAPI.)

### 6. `POST /TRUST/GETSIGN_SYNC?CertThumb=<THUMB>&TaskId=<random-hex32>` ← ЯДРО
- Query: `CertThumb` (каким сертификатом), `TaskId` (случайный uuid без дефисов; на стороне сервера как id операции — можно принимать и игнорировать/логировать).
- Тело: **base64(байты документа для подписи)** (`text/plain`).
- → `Data`: **base64(DER PKCS#7 SignedData)** — открепленная (detached) подпись.

**Крипто-формат подписи (проверено openssl asn1parse):**
- `pkcs7-signedData`, encapContentInfo = `pkcs7-data`, **detached** (документ не вложен).
- Хеш: **ГОСТ Р 34.11-2012, 256 бит**. Подпись: **ГОСТ Р 34.10-2012 (256)**.
- Сертификат подписанта **вложен** в SignedData.certificates.
- Подписанные атрибуты (CAdES-BES): `contentType`, `messageDigest`, `signingTime`,
  `signingCertificateV2` (OID 1.2.840.113549.1.9.16.2.47, ESSCertIDv2).

Реализация через CryptoAPI КриптоПро (либы `/opt/cprocsp/lib/libcapi20.4.dylib` — уже arm64):
`CryptMsgOpenToEncode(CMSG_SIGNED, CMSG_DETACHED_FLAG, &SignedInfo…)` с `HashAlgorithm` = ГОСТ-2012-256,
authenticated attributes добавить вручную (signingTime + signingCertificateV2), скормить документ
`CryptMsgUpdate`, забрать `CMSG_ENCODED_MESSAGE`, base64. PIN Rutoken запрашивает **сам CryptoPro CSP**
(диалог ОС) — демон PIN не трогает.

### 7. `POST /TRUST/GETSIGN_ATT_SYNC?…` (в бинаре; не в этом захвате)
То же, но **attached** (документ вложен в SignedData) — вероятно без `CMSG_DETACHED_FLAG`.

### 8. `POST /TRUST/DECRYPT_SYNC?CertThumb=<THUMB>&TaskId=<hex>` (реализован 2026-10-09)
- Тело: **base64(DER CMS EnvelopedData)** — входящие документы (требования ФНС и т.п.).
- → `Data`: **base64(расшифрованного содержимого)**; сайт без разбора отдаёт его на свой сервер.
- `trustd`: `CryptDecryptMessage` по хранилищу «My» — получателя (сертификат с закрытым ключом)
  CryptoAPI находит сам, `CertThumb` не нужен. Проверено на ГОСТ 28147-89 и «Кузнечике».
- **Без него не работает и подпись**: сессия «Отчётности» сначала расшифровывает входящие,
  и при ошибке расшифровки до операций подписи дело не доходит.

### 9. `POST /TRUST/SIGN_HASH_SYNC?CertThumb=<THUMB>&TaskId=<hex>` (реализован 2026-10-09)
С октября 2026 «Отчётность» может прислать вместо документа **готовый хэш** (операция `HashSignature`).
- Тело: **base64(хэш ГОСТ Р 34.11-2012** документа, 32 байта для ключей 2012-256). `trustd` на всякий
  случай принимает и hex-строку, и base64 от hex-строки.
- → `Data`: **base64(DER PKCS#7 SignedData)** — та же отсоединённая CAdES-BES подпись, что у `GETSIGN_SYNC`,
  но `messageDigest` = переданный хэш (аналог `SignHash` у КриптоПро). Хэш документа, а не готовых
  атрибутов: сайт пробует одни и те же данные с разными сертификатами, значит данные от сертификата
  не зависят.
- В CryptoAPI нельзя подсунуть CryptMsg готовый хэш (он хэширует контент сам), а `libcades` в
  КриптоПро на Mac нет, поэтому SignedData собирается вручную (`signHash` в `trustd.cpp`): атрибуты
  contentType, signingTime, messageDigest, signingCertificateV2 → `CryptSignHash` над их DER-SET →
  подпись **в обратном порядке байт** (CryptoAPI отдаёт little-endian). Проверено: на том же документе
  ASN.1-структура байт-в-байт совпадает с CryptMsg-подписью из `GETSIGN_SYNC` (кроме времени и значения
  подписи), `CMSG_CTRL_VERIFY_SIGNATURE` на исходном документе проходит.

### Как сайт вызывает плагин (crypto center, 2026-10)
Клиент плагина — модуль в `st.mdstatic.org/ecenter/md.*.js` (ищи `"http://localhost:18080"`): все вызовы —
обычный `fetch` на `localhost:18080`. Операции раздаёт сервер (`/eds/crypto/center/api/v1/sessions/state`):
`{Id, Kind, CertificateSerialNumbers, Data}`, где Kind = AttachedSignature (1) / DetachedSignature (2) /
HashSignature (3) / CmsDecryption (4) / XmlForFssDecryption (5, `DECRYPT_FSS_RESPONSE_SYNC`). `Data` уходит
плагину телом запроса, `Data` из ответа — серверу (`/operations`) как есть. Ещё есть `EnumAllCerts`,
`GETRESULT_SYNC` — пока не встречались.

## План замены (arm64-демон в составе «ЭДО Мост»)
1. HTTP-сервер на Swift (Network.framework / NIO) на 127.0.0.1:18080, те же пути + CORS.
2. `GetVer`/`TryUse`/`EnumCerts`/`GetCertBody`/`CheckCert` — прямые вызовы CryptoAPI (несложно).
3. `GETSIGN_SYNC` — CMSG_SIGNED detached, ГОСТ-2012-256, CAdES-BES атрибуты. Ядро работы.
4. Golden-тест: наш ответ на тот же документ ⇒ подпись, которую принимает moedelo.org и `cryptcp -verify`.
5. Встроить демон в MoeDeloBridge (убрать зависимость от StekTrustPlugin целиком).

Референс-захваты и сырые дампы — рядом в `reverse/` (gitignored).
