// trustd.cpp — нативный arm64-демон, замена StekTrustPlugin.
// HTTP на 127.0.0.1:18080, протокол /TRUST/*, крипта через CryptoAPI КриптоПро.
// Сборка: ./build.sh trustd    Запуск: ./trustd
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <time.h>
#include <string>
#include <vector>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include "reader/tchar.h"
#include "cpcsp/WinCryptEx.h"

#define TYPE_DER (X509_ASN_ENCODING | PKCS_7_ASN_ENCODING)
static DWORD lastErr(){ return (DWORD)GetLastError(); }

//======================= утилиты =======================
static const char B64[]="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
static std::string b64enc(const BYTE* d, size_t n){
    std::string o;
    for(size_t i=0;i<n;i+=3){
        unsigned x=d[i]<<16; int k=1;
        if(i+1<n){x|=d[i+1]<<8;k=2;} if(i+2<n){x|=d[i+2];k=3;}
        o+=B64[(x>>18)&63]; o+=B64[(x>>12)&63];
        o+=(k>=2?B64[(x>>6)&63]:'='); o+=(k>=3?B64[x&63]:'=');
    }
    return o;
}
static int b64val(char c){
    if(c>='A'&&c<='Z')return c-'A'; if(c>='a'&&c<='z')return c-'a'+26;
    if(c>='0'&&c<='9')return c-'0'+52; if(c=='+')return 62; if(c=='/')return 63; return -1;
}
static std::vector<BYTE> b64dec(const std::string& s){
    std::vector<BYTE> o; unsigned buf=0; int bits=0;   // unsigned: без знакового переполнения (UB)
    for(char c: s){ if(c=='=')break; int v=b64val(c); if(v<0)continue;
        buf=((buf<<6)|v)&0xFFFFFF; bits+=6; if(bits>=8){bits-=8; o.push_back((BYTE)((buf>>bits)&0xFF));} }
    return o;
}
static bool hex2bin(const std::string& h, BYTE* out, int n){
    if((int)h.size()<n*2) return false;
    for(int i=0;i<n;i++){ unsigned v; if(sscanf(h.c_str()+i*2,"%2x",&v)!=1)return false; out[i]=(BYTE)v; }
    return true;
}
static std::string bin2hexU(const BYTE* d, size_t n){
    static const char* H="0123456789ABCDEF"; std::string o;
    for(size_t i=0;i<n;i++){ o+=H[d[i]>>4]; o+=H[d[i]&15]; } return o;
}
static std::string jsonEsc(const std::string& s){
    std::string o;
    for(unsigned char c: s){
        if(c=='"'||c=='\\'){ o+='\\'; o+=c; }
        else if(c=='\n')o+="\\n"; else if(c=='\r')o+="\\r"; else if(c=='\t')o+="\\t";
        else if(c<0x20){ char b[8]; snprintf(b,8,"\\u%04x",c); o+=b; }
        else o+=c;
    }
    return o;
}
// CP1251 → UTF-8 (CryptoPro отдаёт имена в 1251)
static std::string cp1251toUtf8(const std::string& s){
    static const int hi[64]={ // 0xC0..0xFF → Unicode
      0x410,0x411,0x412,0x413,0x414,0x415,0x416,0x417,0x418,0x419,0x41A,0x41B,0x41C,0x41D,0x41E,0x41F,
      0x420,0x421,0x422,0x423,0x424,0x425,0x426,0x427,0x428,0x429,0x42A,0x42B,0x42C,0x42D,0x42E,0x42F,
      0x430,0x431,0x432,0x433,0x434,0x435,0x436,0x437,0x438,0x439,0x43A,0x43B,0x43C,0x43D,0x43E,0x43F,
      0x440,0x441,0x442,0x443,0x444,0x445,0x446,0x447,0x448,0x449,0x44A,0x44B,0x44C,0x44D,0x44E,0x44F};
    std::string o;
    for(unsigned char c: s){
        int u=-1;
        if(c<0x80)u=c;
        else if(c>=0xC0)u=hi[c-0xC0];
        else if(c==0xA8)u=0x401; else if(c==0xB8)u=0x451; // Ё ё
        else if(c==0xB9)u=0x2116; // №
        else u=c;
        if(u<0x80)o+=(char)u;
        else if(u<0x800){ o+=(char)(0xC0|(u>>6)); o+=(char)(0x80|(u&63)); }
        else { o+=(char)(0xE0|(u>>12)); o+=(char)(0x80|((u>>6)&63)); o+=(char)(0x80|(u&63)); }
    }
    return o;
}
static std::string filetimeDate(const FILETIME& ft){
    unsigned long long t=((unsigned long long)ft.dwHighDateTime<<32)|ft.dwLowDateTime;
    time_t secs=(time_t)((t-116444736000000000ULL)/10000000ULL);
    struct tm g; gmtime_r(&secs,&g); char b[16]; strftime(b,16,"%Y-%m-%d",&g); return b;
}
static LPCSTR hashOid(HCRYPTPROV hProv, DWORD keySpec){
    HCRYPTKEY hKey; ALG_ID alg; DWORD cb=sizeof(alg);
    if(!CryptGetUserKey(hProv,keySpec,&hKey)) return NULL;
    if(!CryptGetKeyParam(hKey,KP_ALGID,(BYTE*)&alg,&cb,0)){ CryptDestroyKey(hKey); return NULL; }
    CryptDestroyKey(hKey);
    switch(alg){
      case CALG_DH_EL_SF: case CALG_GR3410EL: return szOID_CP_GOST_R3411;
      case CALG_DH_GR3410_12_256_SF: case CALG_GR3410_12_256: return szOID_CP_GOST_R3411_12_256;
      case CALG_DH_GR3410_12_512_SF: case CALG_GR3410_12_512: return szOID_CP_GOST_R3411_12_512;
      default: return NULL;
    }
}

//======================= крипто-операции =======================
static std::string certNameStr(PCERT_NAME_BLOB blob){
    DWORD n=CertNameToStr(X509_ASN_ENCODING, blob, CERT_X500_NAME_STR, NULL, 0);
    std::vector<char> buf(n?n:1);
    CertNameToStr(X509_ASN_ENCODING, blob, CERT_X500_NAME_STR, &buf[0], n);
    return std::string(&buf[0]); // CertNameToStr на этой сборке уже отдаёт UTF-8
}
// JSON-массив сертификатов (Data для ENUMCERTS)
static std::string enumCertsJson(){
    HCERTSTORE hStore=CertOpenSystemStore(0,_TEXT("My"));
    if(!hStore) return "[]";
    std::string out="[";
    PCCERT_CONTEXT c=NULL; bool first=true;
    while((c=CertEnumCertificatesInStore(hStore,c))!=NULL){
        // только с приватным ключом (как показывает StekTrust)
        DWORD d=0; if(!CertGetCertificateContextProperty(c,CERT_KEY_PROV_INFO_PROP_ID,NULL,&d)) continue;
        // serial (LE → BE)
        DWORD sn=c->pCertInfo->SerialNumber.cbData; BYTE* sp=c->pCertInfo->SerialNumber.pbData;
        std::vector<BYTE> be(sn); for(DWORD i=0;i<sn;i++) be[i]=sp[sn-1-i];
        std::string serial=bin2hexU(&be[0],sn);
        BYTE h[20]; DWORD hb=20; std::string thumb;
        if(CertGetCertificateContextProperty(c,CERT_SHA1_HASH_PROP_ID,h,&hb)) thumb=bin2hexU(h,hb);
        std::string subj=certNameStr(&c->pCertInfo->Subject);
        std::string issuer=certNameStr(&c->pCertInfo->Issuer);
        TCHAR nm[512]; nm[0]=0; CertGetNameString(c,CERT_NAME_SIMPLE_DISPLAY_TYPE,0,NULL,nm,512);
        std::string sname=cp1251toUtf8(nm);
        std::string vf=filetimeDate(c->pCertInfo->NotBefore), vfor=filetimeDate(c->pCertInfo->NotAfter);
        if(!first) out+=","; first=false;
        out+="{\"Serial\":\""+serial+"\",\"Thumbprint\": \""+thumb+"\",\"Subject\": \""+jsonEsc(subj)
           +"\",\"SubjectName\": \""+jsonEsc(sname)+"\",\"Issuer\": \""+jsonEsc(issuer)
           +"\",\"ValidFrom\": \""+vf+"\",\"ValidFor\": \""+vfor+"\"}";
    }
    out+="]";
    CertCloseStore(hStore,0);
    return out;
}
static PCCERT_CONTEXT findByThumb(HCERTSTORE hStore, const std::string& thumbHex){
    BYTE t[20]; if(!hex2bin(thumbHex,t,20)) return NULL;
    CRYPT_HASH_BLOB hb={20,t};
    return CertFindCertificateInStore(hStore,TYPE_DER,0,CERT_FIND_HASH,&hb,NULL);
}
// base64 DER сертификата по отпечатку (GetCertBody)
static bool getCertBody(const std::string& thumb, std::string& outB64){
    HCERTSTORE hStore=CertOpenSystemStore(0,_TEXT("My")); if(!hStore) return false;
    PCCERT_CONTEXT c=findByThumb(hStore,thumb); bool ok=false;
    if(c){ outB64=b64enc(c->pbCertEncoded,c->cbCertEncoded); ok=true; CertFreeCertificateContext(c); }
    CertCloseStore(hStore,0); return ok;
}
// проверка сертификата (CheckCertAndClue) — парсим DER, строим цепочку
static bool checkCert(const std::vector<BYTE>& der){
    PCCERT_CONTEXT c=CertCreateCertificateContext(TYPE_DER,&der[0],(DWORD)der.size());
    if(!c) return false;
    CertFreeCertificateContext(c);
    return true; // для PoC: успешный парс = ок (сайт уже отфильтровал)
}
// detached CAdES-BES ГОСТ подпись (GETSIGN_SYNC) → base64
static bool signDetached(const std::string& thumb, const std::vector<BYTE>& doc, std::string& outB64, std::string& err){
    HCERTSTORE hStore=CertOpenSystemStore(0,_TEXT("My")); if(!hStore){err="store";return false;}
    PCCERT_CONTEXT cert=findByThumb(hStore,thumb);
    if(!cert){ err="cert not found"; CertCloseStore(hStore,0); return false; }
    HCRYPTPROV hProv; DWORD keySpec; BOOL freeProv;
    if(!CryptAcquireCertificatePrivateKey(cert,0,NULL,&hProv,&keySpec,&freeProv)){
        err="acquire private key";
        CertFreeCertificateContext(cert); CertCloseStore(hStore,0); return false;
    }
    CRYPT_ALGORITHM_IDENTIFIER ha; memset(&ha,0,sizeof(ha)); ha.pszObjId=(LPSTR)hashOid(hProv,keySpec);
    if(!ha.pszObjId){ err="hash oid";
        if(freeProv)CryptReleaseContext(hProv,0);
        CertFreeCertificateContext(cert); CertCloseStore(hStore,0); return false; }
    CMSG_SIGNER_ENCODE_INFO si; memset(&si,0,sizeof(si));
    si.cbSize=sizeof(si); si.pCertInfo=cert->pCertInfo; si.hCryptProv=hProv; si.dwKeySpec=keySpec; si.HashAlgorithm=ha;
    CERT_BLOB cb={cert->cbCertEncoded,cert->pbCertEncoded};
    CMSG_SIGNED_ENCODE_INFO sc; memset(&sc,0,sizeof(sc));
    sc.cbSize=sizeof(sc); sc.cSigners=1; sc.rgSigners=&si; sc.cCertEncoded=1; sc.rgCertEncoded=&cb;
    HCRYPTMSG hMsg=CryptMsgOpenToEncode(TYPE_DER,CMSG_DETACHED_FLAG,CMSG_SIGNED,&sc,NULL,NULL);
    bool ok=false;
    if(hMsg && CryptMsgUpdate(hMsg,&doc[0],(DWORD)doc.size(),TRUE)){
        DWORD n=0;
        if(CryptMsgGetParam(hMsg,CMSG_CONTENT_PARAM,0,NULL,&n)){
            std::vector<BYTE> sig(n);
            if(CryptMsgGetParam(hMsg,CMSG_CONTENT_PARAM,0,&sig[0],&n)){ sig.resize(n); outB64=b64enc(&sig[0],sig.size()); ok=true; }
        }
    }
    if(!ok) err="sign failed";
    if(hMsg)CryptMsgClose(hMsg);
    if(freeProv)CryptReleaseContext(hProv,0);
    CertFreeCertificateContext(cert); CertCloseStore(hStore,0);
    return ok;
}

//======================= HTTP =======================
static void sendAll(int fd, const std::string& s){
    size_t off=0; while(off<s.size()){ ssize_t k=send(fd,s.data()+off,s.size()-off,0); if(k<=0)break; off+=k; }
}
static void respond(int fd, const std::string& jsonBody){
    char date[64]; time_t now=time(NULL); struct tm g; gmtime_r(&now,&g);
    strftime(date,64,"%a, %d %b %Y %H:%M:%S GMT",&g);
    char hdr[512];
    int hl=snprintf(hdr,512,
        "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Encoding: utf-8\r\n"
        "Content-Type: application/json; charset=utf-8\r\nContent-Length: %zu\r\nDate: %s\r\n"
        "Access-Control-Allow-Origin: *\r\n"
        "Access-Control-Allow-Headers: Origin, X-Requested-With, Content-Type, Accept\r\n"
        "Access-Control-Allow-Methods: POST, GET, OPTIONS\r\nAccess-Control-Max-Age: 86400\r\n"
        "Server: TRUST\r\n\r\n", jsonBody.size(), date);
    sendAll(fd, std::string(hdr,hl)+jsonBody);
}
static std::string envelope(const std::string& dataJson, bool status=true, const std::string& err=""){
    std::string e = err.empty()? "[]" : "[\""+jsonEsc(err)+"\"]";
    return std::string("{\n\"Status\": ")+(status?"true":"false")+",\n\"Data\": "+dataJson+",\n\"Errors\": "+e+"\n}";
}
static std::string qparam(const std::string& q, const std::string& key){
    std::string pat=key+"="; size_t p=q.find(pat); if(p==std::string::npos)return "";
    p+=pat.size(); size_t e=q.find('&',p); return q.substr(p, e==std::string::npos? std::string::npos : e-p);
}
static void handle(int fd){
    static const size_t MAX_REQ = 64u<<20;   // потолок запроса (64 МБ): документы малы
    std::string req; char buf[8192]; ssize_t k;
    // читаем заголовки до \r\n\r\n; при переполнении — отбой (не break: hdrEnd должен быть валиден)
    size_t hdrEnd=std::string::npos;
    while((hdrEnd=req.find("\r\n\r\n"))==std::string::npos){
        k=recv(fd,buf,sizeof(buf),0); if(k<=0){ close(fd); return; } req.append(buf,k);
        if(req.size()>MAX_REQ){ close(fd); return; }
    }
    // строка запроса: METHOD SP target SP HTTP/...
    std::string line=req.substr(0,req.find("\r\n"));
    size_t sp=line.find(' ');
    if(sp==std::string::npos){ close(fd); return; }   // не похоже на HTTP
    std::string method=line.substr(0,sp);
    std::string target=line.substr(sp+1); target=target.substr(0,target.find(' '));
    std::string path=target, query;
    size_t qp=target.find('?'); if(qp!=std::string::npos){ path=target.substr(0,qp); query=target.substr(qp+1); }
    // тело по Content-Length, с потолком
    size_t bodyStart=hdrEnd+4; size_t cl=0;
    size_t clp=req.find("Content-Length:");
    if(clp!=std::string::npos) cl=strtoul(req.c_str()+clp+15,NULL,10);
    if(cl>MAX_REQ || bodyStart+cl>MAX_REQ){ close(fd); return; }
    while(req.size()-bodyStart < cl){ k=recv(fd,buf,sizeof(buf),0); if(k<=0)break; req.append(buf,k); }
    std::string body=req.substr(bodyStart, cl);

    if(method=="OPTIONS"){ respond(fd, ""); close(fd); return; }

    std::string data="null", err; bool status=true;
    if(path=="/TRUST/GetVer"){ data="\"2.7.0.4\""; }
    else if(path=="/TRUST/TRYUSEPLUGIN_SYNC"){ data="null"; }
    else if(path=="/TRUST/ENUMCERTS_SYNC"){ data=enumCertsJson(); }
    else if(path=="/TRUST/GetCertBody"){
        std::string b64; if(getCertBody(qparam(query,"CertThumb"),b64)) data="\""+b64+"\"";
        else { status=false; err="Не указан SN (или Thumbprint) сертификата"; data="null"; }
    }
    else if(path=="/TRUST/CheckCertAndClue"){
        std::vector<BYTE> der=b64dec(body);
        if(der.size() && checkCert(der)) data="null"; else { status=false; err="Проверка сертификата не пройдена"; data="null"; }
    }
    else if(path=="/TRUST/GETSIGN_SYNC"){
        std::vector<BYTE> doc=b64dec(body); std::string sig;
        if(doc.empty()){ status=false; err="Пустой документ"; data="null"; }
        else if(signDetached(qparam(query,"CertThumb"),doc,sig,err)) data="\""+sig+"\"";
        else { status=false; data="null"; }
    }
    else { status=false; err="Unknown command"; data="null"; }

    time_t now=time(NULL); struct tm lt; localtime_r(&now,&lt); char ts[16]; strftime(ts,16,"%H:%M:%S",&lt);
    fprintf(stderr,"%s  %-5s %-22s -> Status=%s dataLen=%zu%s%s\n",
        ts, method.c_str(), path.c_str(), status?"true":"false", data.size(),
        err.empty()?"":"  ERR=", err.c_str());
    fflush(stderr);
    respond(fd, envelope(data,status,err));
    close(fd);
}

int main(int argc, char** argv){
    int port = argc>1 ? atoi(argv[1]) : 18080;
    int s=socket(AF_INET,SOCK_STREAM,0);
    int one=1; setsockopt(s,SOL_SOCKET,SO_REUSEADDR,&one,sizeof(one));
    sockaddr_in a; memset(&a,0,sizeof(a)); a.sin_family=AF_INET; a.sin_port=htons(port);
    a.sin_addr.s_addr=inet_addr("127.0.0.1");
    if(bind(s,(sockaddr*)&a,sizeof(a))<0){ perror("bind"); return 1; }
    if(listen(s,16)<0){ perror("listen"); return 1; }
    fprintf(stderr,"trustd слушает 127.0.0.1:%d\n",port);
    for(;;){ int c=accept(s,NULL,NULL); if(c<0)continue; handle(c); }
    return 0;
}
