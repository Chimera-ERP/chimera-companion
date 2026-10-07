# Asociere ERP prin PIN

În ERP: Dispozitive fiscale → Asociază Chimera Companion → locație → Generează PIN Companion.
În Companion: Asociază cu ERP prin PIN → adresa HTTPS ERP → PIN.

PIN-ul expiră după 10 minute, se consumă atomic o singură dată și este separat de PIN-urile POS. Asocierea nu cere QR, login sau passkey de operator. Tokenul și locația sunt păstrate în FlutterSecureStorage și restaurate la redeschidere. Nu există retransmitere automată la pierderea răspunsului; pentru o asociere cu rezultat necunoscut verifică dispozitivele în ERP înainte să generezi alt PIN.

Identitatea are rolul `companion`, fără permisiunile POS. Ștergerea dispozitivului revocă accesul la backend. Această etapă implementează asocierea, nu coada de comenzi hardware ERP/POS.

Migrare auth: `sql/companion_enrollment.sql`. Contul care generează PIN-ul trebuie să aibă `manage_devices`. În dezvoltare pe Android folosește un ERP accesibil prin HTTPS, nu `localhost` de pe laptop.
