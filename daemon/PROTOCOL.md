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

### 8. `POST /TRUST/DECRYPT_SYNC?CertThumb=<THUMB>&TaskId=<hex>` (замечен в трафике)
Расшифровка (CMS enveloped). Для подписи не нужен; реализовать при необходимости.

## План замены (arm64-демон в составе «ЭДО Мост»)
1. HTTP-сервер на Swift (Network.framework / NIO) на 127.0.0.1:18080, те же пути + CORS.
2. `GetVer`/`TryUse`/`EnumCerts`/`GetCertBody`/`CheckCert` — прямые вызовы CryptoAPI (несложно).
3. `GETSIGN_SYNC` — CMSG_SIGNED detached, ГОСТ-2012-256, CAdES-BES атрибуты. Ядро работы.
4. Golden-тест: наш ответ на тот же документ ⇒ подпись, которую принимает moedelo.org и `cryptcp -verify`.
5. Встроить демон в MoeDeloBridge (убрать зависимость от StekTrustPlugin целиком).

Референс-захваты и сырые дампы — рядом в `reverse/` (gitignored).
